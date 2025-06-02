#!/bin/bash
set -e

# Install Houdini and Process Images Script
# This script installs Houdini files for x64 WSA builds

# Define working directory and mount points
WORK_DIR="$(pwd)"
ROOT_MNT="$WORK_DIR/system_root_merged"
SYSTEM_MNT="$ROOT_MNT/system"
VENDOR_MNT="$ROOT_MNT/vendor"

# Get the artifact folder from the build step (passed as argument)
ARTIFACT_FOLDER="$1"
if [ -z "$ARTIFACT_FOLDER" ]; then
    echo "Error: Artifact folder not provided"
    exit 1
fi

WSA_PATH="$WORK_DIR/output/$ARTIFACT_FOLDER"

echo "Expand images"

SYSTEM_IMG_SIZE=$(du --apparent-size -sB512 "$WSA_PATH/system.vhdx" | cut -f1)
VENDOR_IMG_SIZE=$(du --apparent-size -sB512 "$WSA_PATH/vendor.vhdx" | cut -f1)

# Convert vhdx to img for processing
qemu-img convert -f vhdx -O raw "$WSA_PATH/system.vhdx" "$WSA_PATH/system.img"
qemu-img convert -f vhdx -O raw "$WSA_PATH/vendor.vhdx" "$WSA_PATH/vendor.img"

SYSTEM_IMG_SIZE=$(du --apparent-size -sB512 "$WSA_PATH/system.img" | cut -f1)
VENDOR_IMG_SIZE=$(du --apparent-size -sB512 "$WSA_PATH/vendor.img" | cut -f1)

SYSTEM_TARGET_SIZE=$((SYSTEM_IMG_SIZE * 3))
# Calculate vendor size for x64 and Houdini requirements
VENDOR_HOUDINI_SIZE=419430400  # 400MB in bytes for Houdini files
VENDOR_EXTRA_SIZE=209715200    # 200MB extra buffer in bytes
VENDOR_TOTAL_EXTRA=$((VENDOR_HOUDINI_SIZE + VENDOR_EXTRA_SIZE))
VENDOR_TOTAL_EXTRA_BLOCKS=$((VENDOR_TOTAL_EXTRA / 512))  # Convert to 512-byte blocks
VENDOR_TARGET_SIZE=$((VENDOR_IMG_SIZE + VENDOR_TOTAL_EXTRA_BLOCKS))

# Function to abort with error message
abort() {
    echo "Error: $1"
    exit 1
}

# Function to resize image
resize_img() {
    local img_file="$1"
    local target_size="$2"
    
    echo "Checking filesystem integrity for $img_file..."
    e2fsck -f -y "$img_file" || {
        echo "Initial e2fsck failed, attempting forced repair..."
        e2fsck -fy "$img_file" || {
            echo "Failed to repair filesystem, attempting to continue..."
            return 1
        }
    }
    
    if [ -n "$target_size" ]; then
        echo "Expanding $img_file to $target_size bytes..."
        truncate -s "$target_size" "$img_file" || return 1
        echo "Resizing filesystem to fill expanded image..."
        resize2fs "$img_file" || {
            echo "resize2fs failed, attempting e2fsck and retry..."
            e2fsck -fy "$img_file" || return 1
            resize2fs "$img_file" || return 1
        }
    else
        echo "Shrinking $img_file to minimum size..."
        resize2fs -M "$img_file" || {
            echo "resize2fs -M failed, attempting e2fsck and retry..."
            e2fsck -fy "$img_file" || return 1
            resize2fs -M "$img_file" || return 1
        }
    fi
    return 0
}

# Resize images (convert blocks to bytes for truncate)
resize_img "$WSA_PATH/system.img" "$((SYSTEM_TARGET_SIZE * 512))" || abort "Failed to resize system.img"
resize_img "$WSA_PATH/vendor.img" "$((VENDOR_TARGET_SIZE * 512))" || abort "Failed to resize vendor.img"

echo -e "Expand images done\n"

# Function to convert read-only EXT4 image to read-write
ro_ext4_img_to_rw() {
    local img_file="$1"
    echo "Converting $img_file from read-only to read-write..."
    
    # First, check and repair the filesystem
    echo "Checking filesystem integrity before conversion..."
    e2fsck -f -y "$img_file" || {
        echo "e2fsck failed, attempting forced repair..."
        e2fsck -fy "$img_file" || {
            echo "Failed to repair filesystem before conversion"
            return 1
        }
    }
    
    # Get current size and create a temporary expanded size for unshare_blocks operation
    local current_size=$(du --apparent-size -sB512 "$img_file" | cut -f1)
    local temp_size=$((current_size * 2 * 512))
    
    echo "Temporarily expanding $img_file for conversion process..."
    truncate -s "$temp_size" "$img_file" || {
        echo "Failed to expand image for conversion"
        return 1
    }
    
    # Expand the filesystem to fill the temporary space
    resize2fs "$img_file" || {
        echo "Failed to expand filesystem, attempting repair..."
        e2fsck -fy "$img_file" || return 1
        resize2fs "$img_file" || return 1
    }
    
    # Convert to read-write by unsharing blocks
    echo "Converting filesystem to read-write..."
    e2fsck -fp -E unshare_blocks "$img_file" || {
        echo "unshare_blocks failed, attempting alternative method..."
        e2fsck -fy "$img_file" || return 1
    }
    
    # Resize back to appropriate size
    if [[ "$img_file" == *"vendor.img" ]]; then
        echo "Resizing vendor.img back to target size for Houdini..."
        local target_size="$((VENDOR_TARGET_SIZE * 512))"
        truncate -s "$target_size" "$img_file" || return 1
        resize2fs "$img_file" || {
            echo "Failed to resize to target size, attempting repair..."
            e2fsck -fy "$img_file" || return 1
            resize2fs "$img_file" || return 1
        }
    else
        echo "Shrinking $img_file to minimum size..."
        resize2fs -M "$img_file" || {
            echo "Failed to minimize, attempting repair..."
            e2fsck -fy "$img_file" || return 1
            resize2fs -M "$img_file" || return 1
        }
    fi
    
    # Final filesystem check
    echo "Final filesystem check for $img_file..."
    e2fsck -f -y "$img_file" || {
        echo "Warning: Final filesystem check failed, but continuing..."
    }
    
    return 0
}

echo "Remove read-only flag for read-only EXT4 image"

# Add debug information before conversion
echo "Debug: Image information before conversion:"
echo "System image:"
file "$WSA_PATH/system.img"
ls -lh "$WSA_PATH/system.img"
echo "Vendor image:"
file "$WSA_PATH/vendor.img"
ls -lh "$WSA_PATH/vendor.img"

ro_ext4_img_to_rw "$WSA_PATH/system.img" || echo "Failed to convert system.img to read-write"
ro_ext4_img_to_rw "$WSA_PATH/vendor.img" || echo "Failed to convert vendor.img to read-write"
echo -e "Remove read-only flag for read-only EXT4 image done\n"

# Debug: Show actual file sizes after resize operations
echo "Debug: File sizes after resize operations:"
ls -lh "$WSA_PATH/system.img" "$WSA_PATH/vendor.img"

echo "Mount images"

# Final filesystem verification before mounting
echo "Performing final filesystem checks before mounting..."
e2fsck -f -y "$WSA_PATH/system.img" || {
    echo "System image filesystem check failed, attempting repair..."
    e2fsck -fy "$WSA_PATH/system.img" || abort "Cannot repair system.img filesystem"
}

e2fsck -f -y "$WSA_PATH/vendor.img" || {
    echo "Vendor image filesystem check failed, attempting repair..."
    e2fsck -fy "$WSA_PATH/vendor.img" || abort "Cannot repair vendor.img filesystem"
}

echo "Filesystem checks completed successfully"

sudo mkdir -p "$ROOT_MNT"
echo "Mounting system.img..."
sudo mount -t ext4 -o loop "$WSA_PATH/system.img" "$ROOT_MNT" || {
    echo "Failed to mount system.img, checking filesystem status..."
    file "$WSA_PATH/system.img"
    e2fsck -fy "$WSA_PATH/system.img" || true
    abort "Failed to mount system.img"
}

echo "Mounting vendor.img..."
sudo mount -t ext4 -o loop "$WSA_PATH/vendor.img" "$VENDOR_MNT" || {
    echo "Failed to mount vendor.img, checking filesystem status..."
    file "$WSA_PATH/vendor.img"
    e2fsck -fy "$WSA_PATH/vendor.img" || true
    sudo umount "$ROOT_MNT" || true
    abort "Failed to mount vendor.img"
}

echo -e "Mount done\n"

# Check available space before Houdini installation
echo "Checking available space on mounted filesystems..."
df -h "$ROOT_MNT" "$VENDOR_MNT"

# Additional space verification for x64 builds
VENDOR_AVAIL_KB=$(df "$VENDOR_MNT" | tail -1 | awk '{print $4}')
VENDOR_AVAIL_MB=$((VENDOR_AVAIL_KB / 1024))
echo "Vendor partition available space: ${VENDOR_AVAIL_MB}MB"

if [ "$VENDOR_AVAIL_MB" -lt 400 ]; then
    echo "Warning: Vendor partition may not have enough space for Houdini files (400MB needed)"
    echo "Attempting to remount with more space..."
    
    # Unmount and try to expand more
    sudo umount "$VENDOR_MNT" || true
    
    # Add more space (additional 300MB)
    ADDITIONAL_SPACE=$((314572800 / 512))  # 300MB in 512-byte blocks
    NEW_VENDOR_TARGET=$((VENDOR_TARGET_SIZE + ADDITIONAL_SPACE))
    resize_img "$WSA_PATH/vendor.img" "$((NEW_VENDOR_TARGET * 512))" || abort "Failed to expand vendor.img further"
    
    # Remount
    sudo mount -t ext4 -o loop "$WSA_PATH/vendor.img" "$VENDOR_MNT" || abort "Failed to remount vendor.img"
    
    echo "After additional expansion:"
    df -h "$VENDOR_MNT"
fi

# Install Houdini files using local files
echo "Installing Houdini files from local libhoudini folder (Many Thanks to SupremeGamers)"
HOUDINI_LOCAL_PATH="$(realpath ./libhoudini)"

# Verify local Houdini files exist
if [ ! -d "$HOUDINI_LOCAL_PATH" ]; then
    echo "Local Houdini directory not found at $HOUDINI_LOCAL_PATH, skipping Houdini installation"
else
    # Check total size of Houdini files to be copied
    echo "Calculating total size of Houdini files..."
    HOUDINI_SIZE=$(du -sh "$HOUDINI_LOCAL_PATH" | cut -f1)
    echo "Total Houdini files size: $HOUDINI_SIZE"
    
    # Create necessary directories
    sudo mkdir -p "$VENDOR_MNT/etc/binfmt_misc"
    sudo mkdir -p "$VENDOR_MNT/lib"
    sudo mkdir -p "$VENDOR_MNT/lib64"
    sudo mkdir -p "$VENDOR_MNT/bin"
    sudo mkdir -p "$SYSTEM_MNT/bin"

    # Copy binfmt_misc files from local directory with error checking
    echo "Copying binfmt_misc files from local directory..."
    sudo cp "$HOUDINI_LOCAL_PATH/etc/binfmt_misc/arm64_dyn" "$VENDOR_MNT/etc/binfmt_misc/" || abort "Failed to copy arm64_dyn"
    sudo cp "$HOUDINI_LOCAL_PATH/etc/binfmt_misc/arm64_exe" "$VENDOR_MNT/etc/binfmt_misc/" || abort "Failed to copy arm64_exe"
    sudo cp "$HOUDINI_LOCAL_PATH/etc/binfmt_misc/arm_dyn" "$VENDOR_MNT/etc/binfmt_misc/" || abort "Failed to copy arm_dyn"
    sudo cp "$HOUDINI_LOCAL_PATH/etc/binfmt_misc/arm_exe" "$VENDOR_MNT/etc/binfmt_misc/" || abort "Failed to copy arm_exe"

    # Set SELinux properties for binfmt_misc files
    sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT/etc/binfmt_misc/arm64_dyn" || true
    sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT/etc/binfmt_misc/arm64_exe" || true
    sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT/etc/binfmt_misc/arm_dyn" || true
    sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT/etc/binfmt_misc/arm_exe" || true

    # Copy vendor lib files from local directory with error checking
    echo "Copying vendor library files from local directory..."
    sudo cp "$HOUDINI_LOCAL_PATH/lib/libhoudini.so" "$VENDOR_MNT/lib/libhoudini.so" || abort "Failed to copy lib/libhoudini.so"
    sudo cp "$HOUDINI_LOCAL_PATH/lib64/libhoudini.so" "$VENDOR_MNT/lib64/libhoudini.so" || abort "Failed to copy lib64/libhoudini.so"

    # Set proper permissions and ownership for main libhoudini.so files
    sudo chown root:root "$VENDOR_MNT/lib/libhoudini.so"
    sudo chown root:root "$VENDOR_MNT/lib64/libhoudini.so"
    sudo chmod 644 "$VENDOR_MNT/lib/libhoudini.so"
    sudo chmod 644 "$VENDOR_MNT/lib64/libhoudini.so"

    # Set SELinux properties for vendor lib files
    sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" "$VENDOR_MNT/lib/libhoudini.so" || true
    sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" "$VENDOR_MNT/lib64/libhoudini.so" || true

    # Copy vendor bin files from local directory with error checking
    echo "Copying vendor binary files from local directory..."
    sudo cp "$HOUDINI_LOCAL_PATH/bin/houdini" "$VENDOR_MNT/bin/" || abort "Failed to copy bin/houdini"
    sudo cp "$HOUDINI_LOCAL_PATH/bin/houdini64" "$VENDOR_MNT/bin/" || abort "Failed to copy bin/houdini64"

    # Set SELinux properties for vendor bin files
    sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" "$VENDOR_MNT/bin/houdini" || true
    sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" "$VENDOR_MNT/bin/houdini64" || true

    # Copy to system bin and set SELinux properties with error checking
    echo "Copying to system bin..."
    sudo cp "$HOUDINI_LOCAL_PATH/bin/houdini" "$SYSTEM_MNT/bin/" || abort "Failed to copy bin/houdini to system"
    sudo cp "$HOUDINI_LOCAL_PATH/bin/houdini64" "$SYSTEM_MNT/bin/" || abort "Failed to copy bin/houdini64 to system"

    # Set SELinux properties for system bin files
    sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" "$SYSTEM_MNT/bin/houdini" || true
    sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" "$SYSTEM_MNT/bin/houdini64" || true

    # Set ownership and permissions for vendor bin files (root:2000, 755)
    sudo chown root:2000 "$VENDOR_MNT/bin/houdini"
    sudo chown root:2000 "$VENDOR_MNT/bin/houdini64"
    sudo chmod 755 "$VENDOR_MNT/bin/houdini"
    sudo chmod 755 "$VENDOR_MNT/bin/houdini64"

    # Set ownership and permissions for system bin files (root:2000, 755)
    sudo chown root:2000 "$SYSTEM_MNT/bin/houdini"
    sudo chown root:2000 "$SYSTEM_MNT/bin/houdini64"
    sudo chmod 755 "$SYSTEM_MNT/bin/houdini"
    sudo chmod 755 "$SYSTEM_MNT/bin/houdini64"

    # Copy ARM library files to vendor directories
    echo "Copying ARM library files to vendor directories..."
    sudo mkdir -p "$VENDOR_MNT/lib/arm"
    sudo mkdir -p "$VENDOR_MNT/lib64/arm64"
    
    # Check available space before copying large ARM libraries
    echo "Checking available space before copying ARM libraries..."
    df -h "$VENDOR_MNT"

    # Copy all ARM library files from libhoudini/lib64/arm64 to vendor/lib64/arm64
    if [ -d "$HOUDINI_LOCAL_PATH/lib64/arm64" ]; then
        echo "Copying ARM libraries to vendor/lib64/arm64..."
        ARM64_SIZE=$(du -sh "$HOUDINI_LOCAL_PATH/lib64/arm64" 2>/dev/null | cut -f1 || echo "unknown")
        echo "ARM64 libraries size: $ARM64_SIZE"
        if [ "$(ls -A "$HOUDINI_LOCAL_PATH/lib64/arm64" 2>/dev/null)" ]; then
            sudo cp -r "$HOUDINI_LOCAL_PATH/lib64/arm64/"* "$VENDOR_MNT/lib64/arm64/" || abort "Failed to copy ARM64 libraries to vendor/lib64/arm64"
        else
            echo "Warning: No files found in $HOUDINI_LOCAL_PATH/lib64/arm64"
        fi
        # Set permissions and ownership for all files in vendor/lib64/arm64
        sudo find "$VENDOR_MNT/lib64/arm64" -type f -exec chown root:root {} \; 2>/dev/null || true
        sudo find "$VENDOR_MNT/lib64/arm64" -type f -exec chmod 644 {} \; 2>/dev/null || true
        # Set SELinux context for all files in vendor/lib64/arm64
        sudo find "$VENDOR_MNT/lib64/arm64" -type f -exec setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" {} \; 2>/dev/null || echo "Warning: Failed to set SELinux context for some files in vendor/lib64/arm64"
    else
        echo "Warning: ARM64 library directory $HOUDINI_LOCAL_PATH/lib64/arm64 not found"
    fi

    # Copy all files from libhoudini/lib/arm to vendor/lib/arm
    if [ -d "$HOUDINI_LOCAL_PATH/lib/arm" ]; then
        echo "Copying ARM libraries from libhoudini/lib/arm to vendor/lib/arm..."
        ARM_SIZE=$(du -sh "$HOUDINI_LOCAL_PATH/lib/arm" 2>/dev/null | cut -f1 || echo "unknown")
        echo "ARM libraries size: $ARM_SIZE"
        if [ "$(ls -A "$HOUDINI_LOCAL_PATH/lib/arm" 2>/dev/null)" ]; then
            sudo cp -r "$HOUDINI_LOCAL_PATH/lib/arm/"* "$VENDOR_MNT/lib/arm/" || abort "Failed to copy ARM libraries to vendor/lib/arm"
        else
            echo "Warning: No files found in $HOUDINI_LOCAL_PATH/lib/arm"
        fi
        # Set permissions and ownership for all files in vendor/lib/arm
        sudo find "$VENDOR_MNT/lib/arm" -type f -exec chown root:root {} \; 2>/dev/null || true
        sudo find "$VENDOR_MNT/lib/arm" -type f -exec chmod 644 {} \; 2>/dev/null || true
        # Set SELinux context for all files in vendor/lib/arm
        sudo find "$VENDOR_MNT/lib/arm" -type f -exec setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" {} \; 2>/dev/null || echo "Warning: Failed to set SELinux context for some files in vendor/lib/arm"
    else
        echo "Warning: ARM library directory $HOUDINI_LOCAL_PATH/lib/arm not found"
    fi

    # Edit init.windows_x86_64.rc to add Houdini exec commands after mount bind commands
    echo "Editing init.windows_x86_64.rc for Houdini binary format registration..."
    INIT_WINDOWS_RC="$VENDOR_MNT/etc/init/init.windows_x86_64.rc"
    if [ -f "$INIT_WINDOWS_RC" ]; then
        # Create a backup of the original file
        sudo cp "$INIT_WINDOWS_RC" "$INIT_WINDOWS_RC.backup"
        # Create a temporary file for the modifications
        TEMP_RC="/tmp/init_windows_temp.rc"
        # Process the file line by line to add exec commands after mount bind commands
        sudo awk '
        {
            print $0
            if ($0 ~ /mount none \/vendor\/bin\/houdini \/system\/bin\/houdini bind rec/) {
                print "    exec -- /system/bin/sh -c \"echo '"'"':arm_exe:M::\\\\x7f\\\\x45\\\\x4c\\\\x46\\\\x01\\\\x01\\\\x01\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x02\\\\x00\\\\x28::/system/bin/houdini:P'"'"' > /proc/sys/fs/binfmt_misc/register\""
                print "    exec -- /system/bin/sh -c \"echo '"'"':arm_dyn:M::\\\\x7f\\\\x45\\\\x4c\\\\x46\\\\x01\\\\x01\\\\x01\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x03\\\\x00\\\\x28::/system/bin/houdini:P'"'"' >> /proc/sys/fs/binfmt_misc/register\""
            }
            if ($0 ~ /mount none \/vendor\/bin\/houdini64 \/system\/bin\/houdini64 bind rec/) {
                print "    exec -- /system/bin/sh -c \"echo '"'"':arm64_exe:M::\\\\x7f\\\\x45\\\\x4c\\\\x46\\\\x02\\\\x01\\\\x01\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x02\\\\x00\\\\xb7::/system/bin/houdini64:P'"'"' >> /proc/sys/fs/binfmt_misc/register\""
                print "    exec -- /system/bin/sh -c \"echo '"'"':arm64_dyn:M::\\\\x7f\\\\x45\\\\x4c\\\\x46\\\\x02\\\\x01\\\\x01\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x03\\\\x00\\\\xb7::/system/bin/houdini64:P'"'"' >> /proc/sys/fs/binfmt_misc/register\""
            }
        }' "$INIT_WINDOWS_RC" > "$TEMP_RC"
        # Replace the original file with the modified version
        sudo mv "$TEMP_RC" "$INIT_WINDOWS_RC"
        # Set proper SELinux context for the modified init file
        sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$INIT_WINDOWS_RC" || true
        sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$INIT_WINDOWS_RC.backup" || true
        echo "Successfully updated init.windows_x86_64.rc with Houdini exec commands"
    else
        echo "Warning: init.windows_x86_64.rc not found at $INIT_WINDOWS_RC"
    fi
    
    # Final space check after Houdini installation
    echo "Final space check after Houdini installation:"
    df -h "$VENDOR_MNT" "$SYSTEM_MNT"
    echo "Houdini files installation completed successfully"
    echo -e "Houdini files installation completed\n"
fi

echo "Umount images"
sudo find "$ROOT_MNT" -exec touch -hamt 200901010000.00 {} \; || true
sudo umount -v "$VENDOR_MNT" || true
sudo umount -v "$ROOT_MNT" || true
echo -e "Umount done\n"

echo "Shrink images"
resize_img "$WSA_PATH/system.img" || abort "Failed to shrink system.img"

# For vendor image with Houdini, don't minimize completely - keep some buffer space
echo "Preserving space in vendor.img for Houdini installation"
# Calculate current used space and add 100MB buffer
VENDOR_USED=$(du --apparent-size -sB512 "$WSA_PATH/vendor.img" | cut -f1)
VENDOR_BUFFER=$((104857600 / 512))  # 100MB buffer in 512-byte blocks
VENDOR_FINAL_SIZE=$((VENDOR_USED + VENDOR_BUFFER))
resize_img "$WSA_PATH/vendor.img" "$((VENDOR_FINAL_SIZE * 512))" || abort "Failed to resize vendor.img with buffer"

echo -e "Shrink images done\n"

echo "Convert images back to vhdx"
qemu-img convert -q -f raw -o subformat=fixed -O vhdx "$WSA_PATH/system.img" "$WSA_PATH/system.vhdx.new"
qemu-img convert -q -f raw -o subformat=fixed -O vhdx "$WSA_PATH/vendor.img" "$WSA_PATH/vendor.vhdx.new"

# Replace original vhdx files
mv "$WSA_PATH/system.vhdx.new" "$WSA_PATH/system.vhdx"
mv "$WSA_PATH/vendor.vhdx.new" "$WSA_PATH/vendor.vhdx"

rm -f "$WSA_PATH/"*.img
echo -e "Convert images to vhdx done\n"

echo "Houdini installation and image processing completed successfully!"
