# Copyright (C) 2025 MustardChef
# Licensed under the Affero General Public License v3.0 (AGPL-3.0)
#
#!/bin/bash
set -e

# WSA ARM Translation Installer Script
# Supports both libndk and libhoudini translation layers with multiple sources

# Define working directory and mount points
WORK_DIR="$(pwd)"
MOUNT_BASE="$WORK_DIR/mount_temp"

# Default values
ARM_TYPE=""
ARM_SOURCE=""
DIRECTORY=""
ARCHIVE_NAME=""

# Function to show usage
show_usage() {
    echo "Usage: $0 --type <libndk|libhoudini> --source <source> --dir <directory> [--archive <archive_name>]"
    echo ""
    echo "ARM Translation Types:"
    echo "  --type libndk                    Use libndk translation layer"
    echo "  --type libhoudini                Use libhoudini translation layer"
    echo ""
    echo "Sources for libndk:"
    echo "  --source chromeos_zork           AMD's libndk from ChromeOS arcvm image for 'zork' Chromebooks"
    echo ""
    echo "Sources for libhoudini:"
    echo "  --source chromeos_volteer        Intel's libhoudini from ChromeOS arcvm image for 'volteer' Chromebooks"
    echo "  --source hpe-14                  Intel's libhoudini from HPE image from Google Play Games for PC"
    echo "  --source aow-13                  Intel's libhoudini from Tencent's AoW Emulator"
    echo "  --source libhoudini_bluestacks   Intel's libhoudini from BlueStacks"
    echo ""
    echo "Options:"
    echo "  --dir <directory>                Directory containing system.vhdx and vendor.vhdx files"
    echo "  --archive <archive_name>         Create .7z archive with specified name (optional)"
    echo ""
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --type)
            ARM_TYPE="$2"
            shift 2
            ;;
        --source)
            ARM_SOURCE="$2"
            shift 2
            ;;
        --dir)
            DIRECTORY="$2"
            shift 2
            ;;
        --archive)
            ARCHIVE_NAME="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            ;;
        *)
            echo "Error: Unknown parameter $1"
            show_usage
            ;;
    esac
done

# Validate required arguments
if [ -z "$ARM_TYPE" ] || [ -z "$ARM_SOURCE" ] || [ -z "$DIRECTORY" ]; then
    echo "Error: Missing required arguments"
    show_usage
fi

# Validate ARM_TYPE
if [ "$ARM_TYPE" != "libndk" ] && [ "$ARM_TYPE" != "libhoudini" ]; then
    echo "Error: Invalid ARM type. Must be 'libndk' or 'libhoudini'"
    exit 1
fi

# Validate ARM_SOURCE based on ARM_TYPE
if [ "$ARM_TYPE" = "libndk" ]; then
    if [ "$ARM_SOURCE" != "chromeos_zork" ]; then
        echo "Error: Invalid source for libndk. Must be 'chromeos_zork'"
        exit 1
    fi
elif [ "$ARM_TYPE" = "libhoudini" ]; then
    case "$ARM_SOURCE" in
        chromeos_volteer|hpe-14|aow-13|libhoudini_bluestacks)
            ;;
        *)
            echo "Error: Invalid source for libhoudini. Must be one of: chromeos_volteer, hpe-14, aow-13, libhoudini_bluestacks"
            exit 1
            ;;
    esac
fi

# Setup working directory
if [ -n "$ARCHIVE_NAME" ]; then
    # Create source folder and copy files
    WSA_PATH="$DIRECTORY/$ARM_SOURCE"
    echo "Creating working directory: $WSA_PATH"
    mkdir -p "$WSA_PATH"
    
    echo "Copying VHDX files to working directory..."
    cp "$DIRECTORY/system.vhdx" "$WSA_PATH/" || { echo "Error: Failed to copy system.vhdx"; exit 1; }
    cp "$DIRECTORY/vendor.vhdx" "$WSA_PATH/" || { echo "Error: Failed to copy vendor.vhdx"; exit 1; }
else
    # Work directly in the specified directory
    WSA_PATH="$DIRECTORY"
fi

# Verify source files exist
ARM_TRANSLATION_PATH="$WORK_DIR/$ARM_TYPE/$ARM_SOURCE"
if [ ! -d "$ARM_TRANSLATION_PATH" ]; then
    echo "Error: ARM translation files not found at $ARM_TRANSLATION_PATH"
    exit 1
fi

echo "Starting WSA ARM translation installation..."
echo "Type: $ARM_TYPE"
echo "Source: $ARM_SOURCE"
echo "Working directory: $WSA_PATH"
echo "Translation files: $ARM_TRANSLATION_PATH"

# Function to abort with error message
abort() {
    echo "Error: $1"
    cleanup_on_error
    exit 1
}

# Function to cleanup on error
cleanup_on_error() {
    echo "Performing cleanup..."
    sudo umount "$MOUNT_BASE/system" 2>/dev/null || true
    sudo umount "$MOUNT_BASE/vendor" 2>/dev/null || true
    sudo rm -rf "$MOUNT_BASE" 2>/dev/null || true
}

# Verify images exist
if [ ! -f "$WSA_PATH/system.vhdx" ] || [ ! -f "$WSA_PATH/vendor.vhdx" ]; then
    echo "Error: WSA images not found in $WSA_PATH"
    exit 1
fi

# Set up cleanup trap
trap cleanup_on_error EXIT

# Function to process VHDX images to mountable IMG format
process_wsa_images() {
    echo "=== Converting VHDX to IMG format ==="
    
    # Convert system.vhdx to raw
    echo "Converting system.vhdx to raw format..."
    qemu-img convert -f vhdx -O raw "$WSA_PATH/system.vhdx" "$WSA_PATH/system.img" || abort "Failed to convert system.vhdx"
    
    # Convert vendor.vhdx to raw
    echo "Converting vendor.vhdx to raw format..."
    qemu-img convert -f vhdx -O raw "$WSA_PATH/vendor.vhdx" "$WSA_PATH/vendor.img" || abort "Failed to convert vendor.vhdx"
    
    # Remove original vhdx files
    echo "Removing original VHDX files..."
    sudo rm -rf "$WSA_PATH/system.vhdx" || abort "Failed to remove system.vhdx"
    sudo rm -rf "$WSA_PATH/vendor.vhdx" || abort "Failed to remove vendor.vhdx"
    
    # Get current sizes and calculate target sizes
    local system_size=$(du --apparent-size -sB1 "$WSA_PATH/system.img" | cut -f1)
    local vendor_size=$(du --apparent-size -sB1 "$WSA_PATH/vendor.img" | cut -f1)
    
    # System: triple the size, Vendor: add 600MB for translation files
    local system_target_size=$((system_size * 3))
    local vendor_target_size=$((vendor_size + 629145600))
    
    echo "Calculated target sizes:"
    echo "  System: $system_target_size bytes"
    echo "  Vendor: $vendor_target_size bytes"
    
    # Allocate space for system image
    echo "Allocating space for system.img..."
    fallocate -l "$system_target_size" "$WSA_PATH/system.img" || abort "Failed to allocate space for system.img"
    
    # Allocate space for vendor image
    echo "Allocating space for vendor.img..."
    fallocate -l "$vendor_target_size" "$WSA_PATH/vendor.img" || abort "Failed to allocate space for vendor.img"
    
    # Resize filesystems
    echo "Resizing system filesystem..."
    resize2fs "$WSA_PATH/system.img" || abort "Failed to resize system filesystem"
    
    echo "Resizing vendor filesystem..."
    resize2fs "$WSA_PATH/vendor.img" || abort "Failed to resize vendor filesystem"
    
    # Make filesystems writable using unshare_blocks
    echo "Making system.img writable..."
    e2fsck -pf -E unshare_blocks "$WSA_PATH/system.img" || {
        echo "Warning: e2fsck with unshare_blocks failed for system, trying alternative method..."
        echo "y" | e2fsck -E unshare_blocks "$WSA_PATH/system.img" || {
            echo "Warning: Standard unshare_blocks failed for system, using fallback method..."
            e2fsck -fy "$WSA_PATH/system.img" || abort "Failed to prepare system filesystem for read-write access"
        }
    }
    
    echo "Making vendor.img writable..."
    e2fsck -pf -E unshare_blocks "$WSA_PATH/vendor.img" || {
        echo "Warning: e2fsck with unshare_blocks failed for vendor, trying alternative method..."
        echo "y" | e2fsck -E unshare_blocks "$WSA_PATH/vendor.img" || {
            echo "Warning: Standard unshare_blocks failed for vendor, using fallback method..."
            e2fsck -fy "$WSA_PATH/vendor.img" || abort "Failed to prepare vendor filesystem for read-write access"
        }
    }
    
    # Create mount directories and mount images
    echo "Creating mount points and mounting images..."
    mkdir -p "$MOUNT_BASE/system" || abort "Failed to create system mount point"
    mkdir -p "$MOUNT_BASE/vendor" || abort "Failed to create vendor mount point"
    
    sudo mount -t ext4 -o loop "$WSA_PATH/system.img" "$MOUNT_BASE/system" || abort "Failed to mount system.img"
    sudo mount -t ext4 -o loop "$WSA_PATH/vendor.img" "$MOUNT_BASE/vendor" || abort "Failed to mount vendor.img"
    
    echo "Images converted and mounted successfully"
}

# Function to find correct mount paths and check structure
find_correct_mount_paths() {
    local base_system_mount="$MOUNT_BASE/system"
    local base_vendor_mount="$MOUNT_BASE/vendor"
    
    echo "=== Checking mount point structures ==="
    
    # Check system mount structure
    echo "Checking system mount structure..."
    if [ -d "$base_system_mount/bin" ] || [ -d "$base_system_mount/etc" ] || [ -d "$base_system_mount/lib" ]; then
        SYSTEM_ROOT="$base_system_mount"
        echo "Using direct system mount: $SYSTEM_ROOT"
    elif [ -d "$base_system_mount/system/bin" ] || [ -d "$base_system_mount/system/etc" ] || [ -d "$base_system_mount/system/lib" ]; then
        SYSTEM_ROOT="$base_system_mount/system"
        echo "Using nested system path: $SYSTEM_ROOT"
    else
        echo "Warning: Could not find standard system directories. Available directories:"
        ls -la "$base_system_mount/" 2>/dev/null || echo "Cannot list system mount contents"
        SYSTEM_ROOT="$base_system_mount"
        echo "Defaulting to: $SYSTEM_ROOT"
    fi
    
    # Check vendor mount structure
    echo "Checking vendor mount structure..."
    if [ -d "$base_vendor_mount/bin" ] || [ -d "$base_vendor_mount/etc" ] || [ -d "$base_vendor_mount/lib" ]; then
        VENDOR_ROOT="$base_vendor_mount"
        echo "Using direct vendor mount: $VENDOR_ROOT"
    elif [ -d "$base_vendor_mount/vendor/bin" ] || [ -d "$base_vendor_mount/vendor/etc" ] || [ -d "$base_vendor_mount/vendor/lib" ]; then
        VENDOR_ROOT="$base_vendor_mount/vendor"
        echo "Using nested vendor path: $VENDOR_ROOT"
    else
        echo "Warning: Could not find standard vendor directories. Available directories:"
        ls -la "$base_vendor_mount/" 2>/dev/null || echo "Cannot list vendor mount contents"
        VENDOR_ROOT="$base_vendor_mount"
        echo "Defaulting to: $VENDOR_ROOT"
    fi
    
    echo "Final paths:"
    echo "  System root: $SYSTEM_ROOT"
    echo "  Vendor root: $VENDOR_ROOT"
}

# Function to install ARM translation layer
install_arm_translation() {
    echo "=== Installing ARM Translation Layer ($ARM_TYPE - $ARM_SOURCE) ==="
    
    # Find correct mount paths first
    find_correct_mount_paths
    
    local SYSTEM_MNT="$SYSTEM_ROOT"
    local VENDOR_MNT="$VENDOR_ROOT"
    
    # Verify that we can access the mount points
    echo "Verifying mount point accessibility..."
    if [ ! -d "$SYSTEM_MNT" ]; then
        abort "System mount point not accessible: $SYSTEM_MNT"
    fi
    if [ ! -d "$VENDOR_MNT" ]; then
        abort "Vendor mount point not accessible: $VENDOR_MNT"
    fi
    
    echo "Mount points verified successfully"
    echo "  System mount: $SYSTEM_MNT"
    echo "  Vendor mount: $VENDOR_MNT"
    
    if [ "$ARM_TYPE" = "libndk" ]; then
        install_libndk "$SYSTEM_MNT" "$VENDOR_MNT"
    elif [ "$ARM_TYPE" = "libhoudini" ]; then
        install_libhoudini "$SYSTEM_MNT" "$VENDOR_MNT"
    fi
}

# Function to install libndk translation layer
install_libndk() {
    local SYSTEM_MNT="$1"
    local VENDOR_MNT="$2"
    
    echo "Installing libndk translation layer..."
    
    # Remove existing Houdini files from system image
    echo "Removing existing Houdini files from system..."
    sudo rm -f "$SYSTEM_MNT/lib/libhoudini.so" 2>/dev/null || true
    sudo rm -f "$SYSTEM_MNT/lib64/libhoudini.so" 2>/dev/null || true
    sudo rm -rf "$SYSTEM_MNT/lib64/arm64" 2>/dev/null || true
    sudo rm -rf "$SYSTEM_MNT/lib/arm" 2>/dev/null || true
    sudo rm -f "$SYSTEM_MNT/bin/houdini" 2>/dev/null || true
    sudo rm -f "$SYSTEM_MNT/bin/houdini64" 2>/dev/null || true
    sudo rm -rf "$SYSTEM_MNT/etc/binfmt_misc" 2>/dev/null || true
    
    # Remove existing Houdini files from vendor image
    echo "Removing existing Houdini files from vendor..."
    sudo rm -f "$VENDOR_MNT/lib/libhoudini.so" 2>/dev/null || true
    sudo rm -f "$VENDOR_MNT/lib64/libhoudini.so" 2>/dev/null || true
    sudo rm -rf "$VENDOR_MNT/lib64/arm64" 2>/dev/null || true
    sudo rm -rf "$VENDOR_MNT/lib/arm" 2>/dev/null || true
    sudo rm -f "$VENDOR_MNT/bin/houdini" 2>/dev/null || true
    sudo rm -f "$VENDOR_MNT/bin/houdini64" 2>/dev/null || true
    sudo rm -rf "$VENDOR_MNT/etc/binfmt_misc" 2>/dev/null || true
    
    # Edit system build.prop
    echo "Editing system build.prop for libndk..."
    local SYSTEM_BUILD_PROP="$SYSTEM_MNT/build.prop"
    if [ -f "$SYSTEM_BUILD_PROP" ]; then
        sudo cp "$SYSTEM_BUILD_PROP" "$SYSTEM_BUILD_PROP.backup" || abort "Failed to backup system build.prop"
        
        # Change native bridge setting and add libndk properties
        sudo sed -i 's/ro.dalvik.vm.native.bridge=0/ro.dalvik.vm.native.bridge=libndk_translation.so/' "$SYSTEM_BUILD_PROP" || abort "Failed to update native bridge in system build.prop"
        
        # Add libndk properties after the native bridge line
        sudo sed -i '/ro.dalvik.vm.native.bridge=libndk_translation.so/a\
ro.dalvik.vm.isa.arm64=x86_64\
ro.dalvik.vm.isa.arm=x86\
ro.enable.native.bridge.exec=1\
ro.enable.native.bridge.exec64=1\
ro.ndk_translation.version=0.2.3' "$SYSTEM_BUILD_PROP" || abort "Failed to add libndk properties to system build.prop"
    else
        echo "Warning: system build.prop not found"
    fi
    
    # Edit vendor build.prop
    echo "Editing vendor build.prop for libndk..."
    local VENDOR_BUILD_PROP="$VENDOR_MNT/build.prop"
    if [ -f "$VENDOR_BUILD_PROP" ]; then
        sudo cp "$VENDOR_BUILD_PROP" "$VENDOR_BUILD_PROP.backup" || abort "Failed to backup vendor build.prop"
        
        # Change native bridge setting and add libndk properties
        sudo sed -i 's/ro.dalvik.vm.native.bridge=libhoudini.so/ro.dalvik.vm.native.bridge=libndk_translation.so/' "$VENDOR_BUILD_PROP" || abort "Failed to update native bridge in vendor build.prop"
        
        # Add libndk version after the native bridge line
        sudo sed -i '/ro.dalvik.vm.native.bridge=libndk_translation.so/a\
ro.ndk_translation.version=0.2.3' "$VENDOR_BUILD_PROP" || abort "Failed to add libndk version to vendor build.prop"
    else
        echo "Warning: vendor build.prop not found"
    fi
    
    # Remove Houdini mount lines from init.windows_x86_64.rc
    echo "Editing init.windows_x86_64.rc to remove Houdini mounts..."
    local INIT_WINDOWS_RC="$VENDOR_MNT/etc/init/init.windows_x86_64.rc"
    if [ -f "$INIT_WINDOWS_RC" ]; then
        sudo cp "$INIT_WINDOWS_RC" "$INIT_WINDOWS_RC.backup" || abort "Failed to backup init.windows_x86_64.rc"
        
        # Remove Houdini mount lines
        sudo sed -i '/mount none \/vendor\/bin\/houdini \/system\/bin\/houdini bind rec/d' "$INIT_WINDOWS_RC" || abort "Failed to remove houdini mount from init.windows_x86_64.rc"
        sudo sed -i '/mount none \/vendor\/bin\/houdini64 \/system\/bin\/houdini64 bind rec/d' "$INIT_WINDOWS_RC" || abort "Failed to remove houdini64 mount from init.windows_x86_64.rc"
    else
        echo "Warning: init.windows_x86_64.rc not found"
    fi
    
    # Copy libndk files to system
    echo "Copying libndk files to system..."
    install_libndk_files_to_system "$SYSTEM_MNT"
    
    # Copy libndk files to vendor
    echo "Copying libndk files to vendor..."
    install_libndk_files_to_vendor "$VENDOR_MNT"
    
    echo "libndk installation completed"
}

# Function to install libndk files to system
install_libndk_files_to_system() {
    local SYSTEM_MNT="$1"
    
    echo "Installing libndk files to system partition..."
    
    # Create necessary directories
    sudo mkdir -p "$SYSTEM_MNT/bin" "$SYSTEM_MNT/etc/init" "$SYSTEM_MNT/etc" "$SYSTEM_MNT/lib" "$SYSTEM_MNT/lib64" || abort "Failed to create system directories"
    
    # Copy binary files and directories
    echo "Copying binary files to system..."
    sudo cp -avr "$ARM_TRANSLATION_PATH/bin/ndk_translation_program_runner_binfmt_misc" "$SYSTEM_MNT/bin/" || abort "Failed to copy ndk_translation_program_runner_binfmt_misc"
    sudo cp -avr "$ARM_TRANSLATION_PATH/bin/ndk_translation_program_runner_binfmt_misc_arm64" "$SYSTEM_MNT/bin/" || abort "Failed to copy ndk_translation_program_runner_binfmt_misc_arm64"
    sudo cp -avr "$ARM_TRANSLATION_PATH/bin/arm" "$SYSTEM_MNT/bin/" || abort "Failed to copy arm directory"
    sudo cp -avr "$ARM_TRANSLATION_PATH/bin/arm64" "$SYSTEM_MNT/bin/" || abort "Failed to copy arm64 directory"
    
    # Copy etc files
    echo "Copying configuration files to system..."
    sudo cp -avr "$ARM_TRANSLATION_PATH/etc/binfmt_misc" "$SYSTEM_MNT/etc/" || abort "Failed to copy binfmt_misc directory"
    sudo cp -avr "$ARM_TRANSLATION_PATH/etc/init/ndk_translation.rc" "$SYSTEM_MNT/etc/init/" || abort "Failed to copy ndk_translation.rc"
    sudo cp -avr "$ARM_TRANSLATION_PATH/etc/ld.config.arm.txt" "$SYSTEM_MNT/etc/" || abort "Failed to copy ld.config.arm.txt"
    sudo cp -avr "$ARM_TRANSLATION_PATH/etc/ld.config.arm64.txt" "$SYSTEM_MNT/etc/" || abort "Failed to copy ld.config.arm64.txt"
    sudo cp -avr "$ARM_TRANSLATION_PATH/etc/cpuinfo.arm64.txt" "$SYSTEM_MNT/etc/" || abort "Failed to copy cpuinfo.arm64.txt"
    sudo cp -avr "$ARM_TRANSLATION_PATH/etc/cpuinfo.arm.txt" "$SYSTEM_MNT/etc/" || abort "Failed to copy cpuinfo.arm.txt"
    
    # Copy lib directories
    echo "Copying library directories to system..."
    sudo cp -avr "$ARM_TRANSLATION_PATH/lib/arm" "$SYSTEM_MNT/lib/" || abort "Failed to copy lib/arm directory"
    sudo cp -avr "$ARM_TRANSLATION_PATH/lib64/arm64" "$SYSTEM_MNT/lib64/" || abort "Failed to copy lib64/arm64 directory"
    
    # Copy individual library files
    echo "Copying individual library files to system..."
    local libndk_libs=(
        "libndk_translation_exec_region.so"
        "libndk_translation_proxy_libaaudio.so"
        "libndk_translation_proxy_libamidi.so"
        "libndk_translation_proxy_libandroid_runtime.so"
        "libndk_translation_proxy_libandroid.so"
        "libndk_translation_proxy_libbinder_ndk.so"
        "libndk_translation_proxy_libc.so"
        "libndk_translation_proxy_libcamera2ndk.so"
        "libndk_translation_proxy_libEGL.so"
        "libndk_translation_proxy_libGLESv1_CM.so"
        "libndk_translation_proxy_libGLESv2.so"
        "libndk_translation_proxy_libGLESv3.so"
        "libndk_translation_proxy_libjnigraphics.so"
        "libndk_translation_proxy_libmediandk.so"
        "libndk_translation_proxy_libnativehelper.so"
        "libndk_translation_proxy_libnativewindow.so"
        "libndk_translation_proxy_libneuralnetworks.so"
        "libndk_translation_proxy_libOpenMAXAL.so"
        "libndk_translation_proxy_libOpenSLES.so"
        "libndk_translation_proxy_libvulkan.so"
        "libndk_translation_proxy_libwebviewchromium_plat_support.so"
        "libndk_translation.so"
    )
    
    # Copy 64-bit libraries
    for lib in "${libndk_libs[@]}"; do
        if [ -f "$ARM_TRANSLATION_PATH/lib64/$lib" ]; then
            sudo cp "$ARM_TRANSLATION_PATH/lib64/$lib" "$SYSTEM_MNT/lib64/" || echo "Warning: Failed to copy $lib to system lib64"
        fi
    done
    
    # Copy 32-bit libraries
    for lib in "${libndk_libs[@]}"; do
        if [ -f "$ARM_TRANSLATION_PATH/lib/$lib" ]; then
            sudo cp "$ARM_TRANSLATION_PATH/lib/$lib" "$SYSTEM_MNT/lib/" || echo "Warning: Failed to copy $lib to system lib"
        fi
    done
    
    # Set SELinux attributes for system files
    echo "Setting SELinux attributes for system files..."
    sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" "$SYSTEM_MNT/bin/ndk_translation_program_runner_binfmt_misc" || abort "Failed to set SELinux for ndk_translation_program_runner_binfmt_misc"
    sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" "$SYSTEM_MNT/bin/ndk_translation_program_runner_binfmt_misc_arm64" || abort "Failed to set SELinux for ndk_translation_program_runner_binfmt_misc_arm64"
    sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" "$SYSTEM_MNT/bin/arm" || abort "Failed to set SELinux for bin/arm"
    sudo find "$SYSTEM_MNT/bin/arm" -exec sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" {} \; 2>/dev/null || true
    sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" "$SYSTEM_MNT/bin/arm64" || abort "Failed to set SELinux for bin/arm64"
    sudo find "$SYSTEM_MNT/bin/arm64" -exec sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" {} \; 2>/dev/null || true
    sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" "$SYSTEM_MNT/lib/arm" || abort "Failed to set SELinux for lib/arm"
    sudo find "$SYSTEM_MNT/lib/arm" -exec sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" {} \; 2>/dev/null || true
    sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" "$SYSTEM_MNT/etc/init/ndk_translation.rc" || abort "Failed to set SELinux for ndk_translation.rc"
    sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" "$SYSTEM_MNT/etc/binfmt_misc" || abort "Failed to set SELinux for etc/binfmt_misc"
    sudo find "$SYSTEM_MNT/etc/binfmt_misc" -exec sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" {} \; 2>/dev/null || true
    sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" "$SYSTEM_MNT/etc/ld.config.arm.txt" || abort "Failed to set SELinux for ld.config.arm.txt"
    sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" "$SYSTEM_MNT/etc/ld.config.arm64.txt" || abort "Failed to set SELinux for ld.config.arm64.txt"
    sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" "$SYSTEM_MNT/etc/cpuinfo.arm64.txt" || abort "Failed to set SELinux for cpuinfo.arm64.txt"
    sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" "$SYSTEM_MNT/etc/cpuinfo.arm.txt" || abort "Failed to set SELinux for cpuinfo.arm.txt"
    sudo setfattr -n security.selinux -v "u:object_r:system_lib_file:s0" "$SYSTEM_MNT/lib64/arm64" || abort "Failed to set SELinux for lib64/arm64"
    sudo find "$SYSTEM_MNT/lib64/arm64" -exec sudo setfattr -n security.selinux -v "u:object_r:system_lib_file:s0" {} \; 2>/dev/null || true
    
    # Set SELinux for individual library files
    for lib in "${libndk_libs[@]}"; do
        if [ -f "$SYSTEM_MNT/lib64/$lib" ]; then
            sudo setfattr -n security.selinux -v "u:object_r:system_lib_file:s0" "$SYSTEM_MNT/lib64/$lib" || echo "Warning: Failed to set SELinux for $lib in lib64"
        fi
        if [ -f "$SYSTEM_MNT/lib/$lib" ]; then
            sudo setfattr -n security.selinux -v "u:object_r:system_lib_file:s0" "$SYSTEM_MNT/lib/$lib" || echo "Warning: Failed to set SELinux for $lib in lib"
        fi
    done
    
    # Set permissions for system files
    echo "Setting permissions for system files..."
    # Files: -rw-r--r-- (644) and root:root, except bin files
    # Directories: drwxr-xr-x (755) and root:root, except bin directories
    # Bin files: -rwxr-xr-x (755) and root:2000
    # Bin directories: drwxr-x--x (751) and root:2000
    
    sudo chown root:2000 "$SYSTEM_MNT/bin/ndk_translation_program_runner_binfmt_misc" || abort "Failed to set ownership for ndk_translation_program_runner_binfmt_misc"
    sudo chmod 755 "$SYSTEM_MNT/bin/ndk_translation_program_runner_binfmt_misc" || abort "Failed to set permissions for ndk_translation_program_runner_binfmt_misc"
    sudo chown root:2000 "$SYSTEM_MNT/bin/ndk_translation_program_runner_binfmt_misc_arm64" || abort "Failed to set ownership for ndk_translation_program_runner_binfmt_misc_arm64"
    sudo chmod 755 "$SYSTEM_MNT/bin/ndk_translation_program_runner_binfmt_misc_arm64" || abort "Failed to set permissions for ndk_translation_program_runner_binfmt_misc_arm64"
    
    # Set permissions for bin directories and their contents
    sudo chown root:2000 "$SYSTEM_MNT/bin/arm" || abort "Failed to set ownership for bin/arm"
    sudo chmod 751 "$SYSTEM_MNT/bin/arm" || abort "Failed to set permissions for bin/arm"
    sudo find "$SYSTEM_MNT/bin/arm" -type f -exec sudo chown root:2000 {} \; -exec sudo chmod 755 {} \; 2>/dev/null || true
    sudo find "$SYSTEM_MNT/bin/arm" -type d -exec sudo chown root:2000 {} \; -exec sudo chmod 751 {} \; 2>/dev/null || true
    
    sudo chown root:2000 "$SYSTEM_MNT/bin/arm64" || abort "Failed to set ownership for bin/arm64"
    sudo chmod 751 "$SYSTEM_MNT/bin/arm64" || abort "Failed to set permissions for bin/arm64"
    sudo find "$SYSTEM_MNT/bin/arm64" -type f -exec sudo chown root:2000 {} \; -exec sudo chmod 755 {} \; 2>/dev/null || true
    sudo find "$SYSTEM_MNT/bin/arm64" -type d -exec sudo chown root:2000 {} \; -exec sudo chmod 751 {} \; 2>/dev/null || true
    
    # Set permissions for non-bin files and directories
    sudo find "$SYSTEM_MNT/etc" -type f -exec sudo chown root:root {} \; -exec sudo chmod 644 {} \; 2>/dev/null || true
    sudo find "$SYSTEM_MNT/etc" -type d -exec sudo chown root:root {} \; -exec sudo chmod 755 {} \; 2>/dev/null || true
    sudo find "$SYSTEM_MNT/lib/arm" -type f -exec sudo chown root:root {} \; -exec sudo chmod 644 {} \; 2>/dev/null || true
    sudo find "$SYSTEM_MNT/lib/arm" -type d -exec sudo chown root:root {} \; -exec sudo chmod 755 {} \; 2>/dev/null || true
    sudo find "$SYSTEM_MNT/lib64/arm64" -type f -exec sudo chown root:root {} \; -exec sudo chmod 644 {} \; 2>/dev/null || true
    sudo find "$SYSTEM_MNT/lib64/arm64" -type d -exec sudo chown root:root {} \; -exec sudo chmod 755 {} \; 2>/dev/null || true
    
    # Set permissions for individual library files
    for lib in "${libndk_libs[@]}"; do
        if [ -f "$SYSTEM_MNT/lib64/$lib" ]; then
            sudo chown root:root "$SYSTEM_MNT/lib64/$lib" || echo "Warning: Failed to set ownership for $lib in lib64"
            sudo chmod 644 "$SYSTEM_MNT/lib64/$lib" || echo "Warning: Failed to set permissions for $lib in lib64"
        fi
        if [ -f "$SYSTEM_MNT/lib/$lib" ]; then
            sudo chown root:root "$SYSTEM_MNT/lib/$lib" || echo "Warning: Failed to set ownership for $lib in lib"
            sudo chmod 644 "$SYSTEM_MNT/lib/$lib" || echo "Warning: Failed to set permissions for $lib in lib"
        fi
    done
    
    echo "System libndk installation completed"
}

# Function to install libndk files to vendor
install_libndk_files_to_vendor() {
    local VENDOR_MNT="$1"
    
    echo "Installing libndk files to vendor partition..."
    
    # Create necessary directories
    sudo mkdir -p "$VENDOR_MNT/bin" "$VENDOR_MNT/etc" "$VENDOR_MNT/lib" "$VENDOR_MNT/lib64" || abort "Failed to create vendor directories"
    
    # Copy binary files and directories
    echo "Copying binary files to vendor..."
    sudo cp -avr "$ARM_TRANSLATION_PATH/bin/ndk_translation_program_runner_binfmt_misc" "$VENDOR_MNT/bin/" || abort "Failed to copy ndk_translation_program_runner_binfmt_misc to vendor"
    sudo cp -avr "$ARM_TRANSLATION_PATH/bin/ndk_translation_program_runner_binfmt_misc_arm64" "$VENDOR_MNT/bin/" || abort "Failed to copy ndk_translation_program_runner_binfmt_misc_arm64 to vendor"
    sudo cp -avr "$ARM_TRANSLATION_PATH/bin/arm" "$VENDOR_MNT/bin/" || abort "Failed to copy arm directory to vendor"
    sudo cp -avr "$ARM_TRANSLATION_PATH/bin/arm64" "$VENDOR_MNT/bin/" || abort "Failed to copy arm64 directory to vendor"
    
    # Copy etc files
    echo "Copying configuration files to vendor..."
    sudo cp -avr "$ARM_TRANSLATION_PATH/etc/binfmt_misc" "$VENDOR_MNT/etc/" || abort "Failed to copy binfmt_misc directory to vendor"
    sudo cp -avr "$ARM_TRANSLATION_PATH/etc/ld.config.arm.txt" "$VENDOR_MNT/etc/" || abort "Failed to copy ld.config.arm.txt to vendor"
    sudo cp -avr "$ARM_TRANSLATION_PATH/etc/ld.config.arm64.txt" "$VENDOR_MNT/etc/" || abort "Failed to copy ld.config.arm64.txt to vendor"
    sudo cp -avr "$ARM_TRANSLATION_PATH/etc/cpuinfo.arm64.txt" "$VENDOR_MNT/etc/" || abort "Failed to copy cpuinfo.arm64.txt to vendor"
    sudo cp -avr "$ARM_TRANSLATION_PATH/etc/cpuinfo.arm.txt" "$VENDOR_MNT/etc/" || abort "Failed to copy cpuinfo.arm.txt to vendor"
    
    # Copy lib directories
    echo "Copying library directories to vendor..."
    sudo cp -avr "$ARM_TRANSLATION_PATH/lib/arm" "$VENDOR_MNT/lib/" || abort "Failed to copy lib/arm directory to vendor"
    sudo cp -avr "$ARM_TRANSLATION_PATH/lib64/arm64" "$VENDOR_MNT/lib64/" || abort "Failed to copy lib64/arm64 directory to vendor"
    
    # Copy individual library files
    echo "Copying individual library files to vendor..."
    local libndk_libs=(
        "libndk_translation_exec_region.so"
        "libndk_translation_proxy_libaaudio.so"
        "libndk_translation_proxy_libamidi.so"
        "libndk_translation_proxy_libandroid_runtime.so"
        "libndk_translation_proxy_libandroid.so"
        "libndk_translation_proxy_libbinder_ndk.so"
        "libndk_translation_proxy_libc.so"
        "libndk_translation_proxy_libcamera2ndk.so"
        "libndk_translation_proxy_libEGL.so"
        "libndk_translation_proxy_libGLESv1_CM.so"
        "libndk_translation_proxy_libGLESv2.so"
        "libndk_translation_proxy_libGLESv3.so"
        "libndk_translation_proxy_libjnigraphics.so"
        "libndk_translation_proxy_libmediandk.so"
        "libndk_translation_proxy_libnativehelper.so"
        "libndk_translation_proxy_libnativewindow.so"
        "libndk_translation_proxy_libneuralnetworks.so"
        "libndk_translation_proxy_libOpenMAXAL.so"
        "libndk_translation_proxy_libOpenSLES.so"
        "libndk_translation_proxy_libvulkan.so"
        "libndk_translation_proxy_libwebviewchromium_plat_support.so"
        "libndk_translation.so"
    )
    
    # Copy 64-bit libraries
    for lib in "${libndk_libs[@]}"; do
        if [ -f "$ARM_TRANSLATION_PATH/lib64/$lib" ]; then
            sudo cp "$ARM_TRANSLATION_PATH/lib64/$lib" "$VENDOR_MNT/lib64/" || echo "Warning: Failed to copy $lib to vendor lib64"
        fi
    done
    
    # Copy 32-bit libraries
    for lib in "${libndk_libs[@]}"; do
        if [ -f "$ARM_TRANSLATION_PATH/lib/$lib" ]; then
            sudo cp "$ARM_TRANSLATION_PATH/lib/$lib" "$VENDOR_MNT/lib/" || echo "Warning: Failed to copy $lib to vendor lib"
        fi
    done
    
    # Set SELinux attributes for vendor files
    echo "Setting SELinux attributes for vendor files..."
    sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" "$VENDOR_MNT/bin/ndk_translation_program_runner_binfmt_misc" || abort "Failed to set SELinux for ndk_translation_program_runner_binfmt_misc in vendor"
    sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" "$VENDOR_MNT/bin/ndk_translation_program_runner_binfmt_misc_arm64" || abort "Failed to set SELinux for ndk_translation_program_runner_binfmt_misc_arm64 in vendor"
    sudo setfattr -n security.selinux -v "u:object_r:vendor_file:s0" "$VENDOR_MNT/bin/arm" || abort "Failed to set SELinux for vendor bin/arm"
    sudo find "$VENDOR_MNT/bin/arm" -exec sudo setfattr -n security.selinux -v "u:object_r:vendor_file:s0" {} \; 2>/dev/null || true
    sudo setfattr -n security.selinux -v "u:object_r:vendor_file:s0" "$VENDOR_MNT/bin/arm64" || abort "Failed to set SELinux for vendor bin/arm64"
    sudo find "$VENDOR_MNT/bin/arm64" -exec sudo setfattr -n security.selinux -v "u:object_r:vendor_file:s0" {} \; 2>/dev/null || true
    sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT/etc/binfmt_misc" || abort "Failed to set SELinux for vendor etc/binfmt_misc"
    sudo find "$VENDOR_MNT/etc/binfmt_misc" -exec sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" {} \; 2>/dev/null || true
    sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT/etc/ld.config.arm.txt" || abort "Failed to set SELinux for vendor ld.config.arm.txt"
    sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT/etc/ld.config.arm64.txt" || abort "Failed to set SELinux for vendor ld.config.arm64.txt"
    sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT/etc/cpuinfo.arm64.txt" || abort "Failed to set SELinux for vendor cpuinfo.arm64.txt"
    sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT/etc/cpuinfo.arm.txt" || abort "Failed to set SELinux for vendor cpuinfo.arm.txt"
    sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" "$VENDOR_MNT/lib/arm" || abort "Failed to set SELinux for vendor lib/arm"
    sudo find "$VENDOR_MNT/lib/arm" -exec sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" {} \; 2>/dev/null || true
    sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" "$VENDOR_MNT/lib64/arm64" || abort "Failed to set SELinux for vendor lib64/arm64"
    sudo find "$VENDOR_MNT/lib64/arm64" -exec sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" {} \; 2>/dev/null || true
    
    # Set SELinux for individual library files
    for lib in "${libndk_libs[@]}"; do
        if [ -f "$VENDOR_MNT/lib64/$lib" ]; then
            sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" "$VENDOR_MNT/lib64/$lib" || echo "Warning: Failed to set SELinux for $lib in vendor lib64"
        fi
        if [ -f "$VENDOR_MNT/lib/$lib" ]; then
            sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" "$VENDOR_MNT/lib/$lib" || echo "Warning: Failed to set SELinux for $lib in vendor lib"
        fi
    done
    
    # Set permissions for vendor files
    echo "Setting permissions for vendor files..."
    # Files: -rw-r--r-- (644) and root:root, except bin files and binfmt_misc
    # Directories: drwxr-xr-x (755) and root:root, except bin directories and binfmt_misc
    # Bin files: -rwxr-xr-x (755) and root:2000
    # Bin directories: drwxr-x--x (751) and root:2000
    # binfmt_misc directory: drwxr-xr-x (755) and root:2000
    # binfmt_misc files: -rw-r--r-- (644) and root:root
    
    sudo chown root:2000 "$VENDOR_MNT/bin/ndk_translation_program_runner_binfmt_misc" || abort "Failed to set ownership for vendor ndk_translation_program_runner_binfmt_misc"
    sudo chmod 755 "$VENDOR_MNT/bin/ndk_translation_program_runner_binfmt_misc" || abort "Failed to set permissions for vendor ndk_translation_program_runner_binfmt_misc"
    sudo chown root:2000 "$VENDOR_MNT/bin/ndk_translation_program_runner_binfmt_misc_arm64" || abort "Failed to set ownership for vendor ndk_translation_program_runner_binfmt_misc_arm64"
    sudo chmod 755 "$VENDOR_MNT/bin/ndk_translation_program_runner_binfmt_misc_arm64" || abort "Failed to set permissions for vendor ndk_translation_program_runner_binfmt_misc_arm64"
    
    # Set permissions for bin directories and their contents
    sudo chown root:2000 "$VENDOR_MNT/bin/arm" || abort "Failed to set ownership for vendor bin/arm"
    sudo chmod 751 "$VENDOR_MNT/bin/arm" || abort "Failed to set permissions for vendor bin/arm"
    sudo find "$VENDOR_MNT/bin/arm" -type f -exec sudo chown root:2000 {} \; -exec sudo chmod 755 {} \; 2>/dev/null || true
    sudo find "$VENDOR_MNT/bin/arm" -type d -exec sudo chown root:2000 {} \; -exec sudo chmod 751 {} \; 2>/dev/null || true
    
    sudo chown root:2000 "$VENDOR_MNT/bin/arm64" || abort "Failed to set ownership for vendor bin/arm64"
    sudo chmod 751 "$VENDOR_MNT/bin/arm64" || abort "Failed to set permissions for vendor bin/arm64"
    sudo find "$VENDOR_MNT/bin/arm64" -type f -exec sudo chown root:2000 {} \; -exec sudo chmod 755 {} \; 2>/dev/null || true
    sudo find "$VENDOR_MNT/bin/arm64" -type d -exec sudo chown root:2000 {} \; -exec sudo chmod 751 {} \; 2>/dev/null || true
    
    # Special handling for binfmt_misc directory
    sudo chown root:2000 "$VENDOR_MNT/etc/binfmt_misc" || abort "Failed to set ownership for vendor etc/binfmt_misc"
    sudo chmod 755 "$VENDOR_MNT/etc/binfmt_misc" || abort "Failed to set permissions for vendor etc/binfmt_misc"
    sudo find "$VENDOR_MNT/etc/binfmt_misc" -type f -exec sudo chown root:root {} \; -exec sudo chmod 644 {} \; 2>/dev/null || true
    
    # Set permissions for other etc files
    sudo find "$VENDOR_MNT/etc" -name "*.txt" -exec sudo chown root:root {} \; -exec sudo chmod 644 {} \; 2>/dev/null || true
    
    # Set permissions for lib directories and files
    sudo find "$VENDOR_MNT/lib/arm" -type f -exec sudo chown root:root {} \; -exec sudo chmod 644 {} \; 2>/dev/null || true
    sudo find "$VENDOR_MNT/lib/arm" -type d -exec sudo chown root:root {} \; -exec sudo chmod 755 {} \; 2>/dev/null || true
    sudo find "$VENDOR_MNT/lib64/arm64" -type f -exec sudo chown root:root {} \; -exec sudo chmod 644 {} \; 2>/dev/null || true
    sudo find "$VENDOR_MNT/lib64/arm64" -type d -exec sudo chown root:root {} \; -exec sudo chmod 755 {} \; 2>/dev/null || true
    
    # Set permissions for individual library files
    for lib in "${libndk_libs[@]}"; do
        if [ -f "$VENDOR_MNT/lib64/$lib" ]; then
            sudo chown root:root "$VENDOR_MNT/lib64/$lib" || echo "Warning: Failed to set ownership for $lib in vendor lib64"
            sudo chmod 644 "$VENDOR_MNT/lib64/$lib" || echo "Warning: Failed to set permissions for $lib in vendor lib64"
        fi
        if [ -f "$VENDOR_MNT/lib/$lib" ]; then
            sudo chown root:root "$VENDOR_MNT/lib/$lib" || echo "Warning: Failed to set ownership for $lib in vendor lib"
            sudo chmod 644 "$VENDOR_MNT/lib/$lib" || echo "Warning: Failed to set permissions for $lib in vendor lib"
        fi
    done
    
    echo "Vendor libndk installation completed"
}

# Function to install libhoudini translation layer
install_libhoudini() {
    local SYSTEM_MNT="$1"
    local VENDOR_MNT="$2"
    
    echo "Installing libhoudini translation layer..."
    
    # Create necessary directories
    sudo mkdir -p "$VENDOR_MNT/etc/binfmt_misc" "$VENDOR_MNT/lib" "$VENDOR_MNT/lib64" "$VENDOR_MNT/bin" || abort "Failed to create vendor directories"
    sudo mkdir -p "$SYSTEM_MNT/bin" || abort "Failed to create system bin directory"
    
    # Handle libhoudini_bluestacks special case
    local native_bridge_lib="libhoudini.so"
    if [ "$ARM_SOURCE" = "libhoudini_bluestacks" ]; then
        native_bridge_lib="libnb.so"
        echo "Using libnb.so for BlueStacks source"
    fi
    
    # Copy binfmt_misc files
    echo "Copying binfmt_misc files..."
    sudo cp "$ARM_TRANSLATION_PATH/etc/binfmt_misc/arm64_dyn" "$VENDOR_MNT/etc/binfmt_misc/" || abort "Failed to copy arm64_dyn"
    sudo cp "$ARM_TRANSLATION_PATH/etc/binfmt_misc/arm64_exe" "$VENDOR_MNT/etc/binfmt_misc/" || abort "Failed to copy arm64_exe"
    sudo cp "$ARM_TRANSLATION_PATH/etc/binfmt_misc/arm_dyn" "$VENDOR_MNT/etc/binfmt_misc/" || abort "Failed to copy arm_dyn"
    sudo cp "$ARM_TRANSLATION_PATH/etc/binfmt_misc/arm_exe" "$VENDOR_MNT/etc/binfmt_misc/" || abort "Failed to copy arm_exe"
    
    # Set SELinux properties for binfmt_misc files
    sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT/etc/binfmt_misc/arm64_dyn" || abort "Failed to set SELinux context for arm64_dyn"
    sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT/etc/binfmt_misc/arm64_exe" || abort "Failed to set SELinux context for arm64_exe"
    sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT/etc/binfmt_misc/arm_dyn" || abort "Failed to set SELinux context for arm_dyn"
    sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$VENDOR_MNT/etc/binfmt_misc/arm_exe" || abort "Failed to set SELinux context for arm_exe"
    
    # Copy main library files
    echo "Copying main library files..."
    if [ "$ARM_SOURCE" = "libhoudini_bluestacks" ]; then
        # Copy both libhoudini.so and libnb.so for BlueStacks
        sudo cp "$ARM_TRANSLATION_PATH/lib/libhoudini.so" "$VENDOR_MNT/lib/libhoudini.so" || abort "Failed to copy 32-bit libhoudini.so"
        sudo cp "$ARM_TRANSLATION_PATH/lib64/libhoudini.so" "$VENDOR_MNT/lib64/libhoudini.so" || abort "Failed to copy 64-bit libhoudini.so"
        sudo cp "$ARM_TRANSLATION_PATH/lib/libnb.so" "$VENDOR_MNT/lib/libnb.so" || abort "Failed to copy 32-bit libnb.so"
        sudo cp "$ARM_TRANSLATION_PATH/lib64/libnb.so" "$VENDOR_MNT/lib64/libnb.so" || abort "Failed to copy 64-bit libnb.so"
        
        # Set permissions and SELinux for libnb.so files
        sudo chown root:root "$VENDOR_MNT/lib/libnb.so" "$VENDOR_MNT/lib64/libnb.so" || abort "Failed to set ownership for libnb.so files"
        sudo chmod 644 "$VENDOR_MNT/lib/libnb.so" "$VENDOR_MNT/lib64/libnb.so" || abort "Failed to set permissions for libnb.so files"
        sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" "$VENDOR_MNT/lib/libnb.so" || abort "Failed to set SELinux context for 32-bit libnb.so"
        sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" "$VENDOR_MNT/lib64/libnb.so" || abort "Failed to set SELinux context for 64-bit libnb.so"
    else
        sudo cp "$ARM_TRANSLATION_PATH/lib/libhoudini.so" "$VENDOR_MNT/lib/libhoudini.so" || abort "Failed to copy 32-bit libhoudini.so"
        sudo cp "$ARM_TRANSLATION_PATH/lib64/libhoudini.so" "$VENDOR_MNT/lib64/libhoudini.so" || abort "Failed to copy 64-bit libhoudini.so"
    fi
    
    # Set proper permissions and ownership for main libhoudini.so files
    sudo chown root:root "$VENDOR_MNT/lib/libhoudini.so" "$VENDOR_MNT/lib64/libhoudini.so" || abort "Failed to set ownership for libhoudini.so files"
    sudo chmod 644 "$VENDOR_MNT/lib/libhoudini.so" "$VENDOR_MNT/lib64/libhoudini.so" || abort "Failed to set permissions for libhoudini.so files"
    
    # Set SELinux properties for vendor lib files
    sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" "$VENDOR_MNT/lib/libhoudini.so" || abort "Failed to set SELinux context for 32-bit libhoudini.so"
    sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" "$VENDOR_MNT/lib64/libhoudini.so" || abort "Failed to set SELinux context for 64-bit libhoudini.so"
    
    # Copy vendor bin files
    echo "Copying vendor binary files..."
    sudo cp "$ARM_TRANSLATION_PATH/bin/houdini" "$VENDOR_MNT/bin/" || abort "Failed to copy houdini to vendor bin"
    sudo cp "$ARM_TRANSLATION_PATH/bin/houdini64" "$VENDOR_MNT/bin/" || abort "Failed to copy houdini64 to vendor bin"
    
    # Set SELinux properties for vendor bin files
    sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" "$VENDOR_MNT/bin/houdini" || abort "Failed to set SELinux context for vendor houdini"
    sudo setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" "$VENDOR_MNT/bin/houdini64" || abort "Failed to set SELinux context for vendor houdini64"
    
    # Copy to system bin and set SELinux properties
    echo "Copying to system bin..."
    sudo cp "$ARM_TRANSLATION_PATH/bin/houdini" "$SYSTEM_MNT/bin/" || abort "Failed to copy houdini to system bin"
    sudo cp "$ARM_TRANSLATION_PATH/bin/houdini64" "$SYSTEM_MNT/bin/" || abort "Failed to copy houdini64 to system bin"
    
    # Set SELinux properties for system bin files
    sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" "$SYSTEM_MNT/bin/houdini" || abort "Failed to set SELinux context for system houdini"
    sudo setfattr -n security.selinux -v "u:object_r:system_file:s0" "$SYSTEM_MNT/bin/houdini64" || abort "Failed to set SELinux context for system houdini64"
    
    # Set ownership and permissions for vendor bin files (root:2000, 755)
    sudo chown root:2000 "$VENDOR_MNT/bin/houdini" "$VENDOR_MNT/bin/houdini64" || abort "Failed to set ownership for vendor bin files"
    sudo chmod 755 "$VENDOR_MNT/bin/houdini" "$VENDOR_MNT/bin/houdini64" || abort "Failed to set permissions for vendor bin files"
    
    # Set ownership and permissions for system bin files (root:2000, 755)
    sudo chown root:2000 "$SYSTEM_MNT/bin/houdini" "$SYSTEM_MNT/bin/houdini64" || abort "Failed to set ownership for system bin files"
    sudo chmod 755 "$SYSTEM_MNT/bin/houdini" "$SYSTEM_MNT/bin/houdini64" || abort "Failed to set permissions for system bin files"
    
    # Copy ARM library files to vendor directories
    echo "Copying ARM library files to vendor directories..."
    sudo mkdir -p "$VENDOR_MNT/lib/arm" "$VENDOR_MNT/lib64/arm64" || abort "Failed to create ARM library directories"
    
    # Copy ARM64 libraries
    if [ -d "$ARM_TRANSLATION_PATH/lib64/arm64" ]; then
        echo "Copying ARM64 libraries..."
        if [ "$(ls -A "$ARM_TRANSLATION_PATH/lib64/arm64" 2>/dev/null)" ]; then
            sudo cp -r "$ARM_TRANSLATION_PATH/lib64/arm64/"* "$VENDOR_MNT/lib64/arm64/" || echo "Warning: Copy failed for ARM64 libraries"
        fi
        
        # Set permissions and ownership for ARM64 files
        sudo find "$VENDOR_MNT/lib64/arm64" -type f -exec chown root:root {} \; -exec chmod 644 {} \; 2>/dev/null || true
        sudo find "$VENDOR_MNT/lib64/arm64" -type f -exec setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" {} \; 2>/dev/null || true
    fi
    
    # Copy ARM32 libraries
    if [ -d "$ARM_TRANSLATION_PATH/lib/arm" ]; then
        echo "Copying ARM32 libraries..."
        if [ "$(ls -A "$ARM_TRANSLATION_PATH/lib/arm" 2>/dev/null)" ]; then
            sudo cp -r "$ARM_TRANSLATION_PATH/lib/arm/"* "$VENDOR_MNT/lib/arm/" || echo "Warning: Copy failed for ARM32 libraries"
        fi
        
        # Set permissions and ownership for ARM32 files
        sudo find "$VENDOR_MNT/lib/arm" -type f -exec chown root:root {} \; -exec chmod 644 {} \; 2>/dev/null || true
        sudo find "$VENDOR_MNT/lib/arm" -type f -exec setfattr -n security.selinux -v "u:object_r:same_process_hal_file:s0" {} \; 2>/dev/null || true
    fi
    
    # Edit init.windows_x86_64.rc to add Houdini exec commands
    echo "Editing init.windows_x86_64.rc for Houdini binary format registration..."
    local INIT_WINDOWS_RC="$VENDOR_MNT/etc/init/init.windows_x86_64.rc"
    
    if [ -f "$INIT_WINDOWS_RC" ]; then
        sudo cp "$INIT_WINDOWS_RC" "$INIT_WINDOWS_RC.backup" || abort "Failed to create backup of init.windows_x86_64.rc"
        
        # Create a temporary file for the modifications
        local TEMP_RC="/tmp/init_windows_temp.rc"
        
        # Process the file to add exec commands after mount bind commands
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
        }' "$INIT_WINDOWS_RC" > "$TEMP_RC" || abort "Failed to process init.windows_x86_64.rc"
        
        sudo mv "$TEMP_RC" "$INIT_WINDOWS_RC" || abort "Failed to replace init.windows_x86_64.rc"
        sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$INIT_WINDOWS_RC" || abort "Failed to set SELinux context for init.windows_x86_64.rc"
        sudo setfattr -n security.selinux -v "u:object_r:vendor_configs_file:s0" "$INIT_WINDOWS_RC.backup" || abort "Failed to set SELinux context for init.windows_x86_64.rc.backup"
        
        echo "Successfully updated init.windows_x86_64.rc with Houdini exec commands"
    else
        echo "Warning: init.windows_x86_64.rc not found"
    fi
    
    # Update build.prop for BlueStacks special case
    if [ "$ARM_SOURCE" = "libhoudini_bluestacks" ]; then
        echo "Updating vendor build.prop for BlueStacks (using libnb.so)..."
        local VENDOR_BUILD_PROP="$VENDOR_MNT/build.prop"
        if [ -f "$VENDOR_BUILD_PROP" ]; then
            sudo cp "$VENDOR_BUILD_PROP" "$VENDOR_BUILD_PROP.backup" || abort "Failed to backup vendor build.prop"
            sudo sed -i 's/ro.dalvik.vm.native.bridge=libhoudini.so/ro.dalvik.vm.native.bridge=libnb.so/' "$VENDOR_BUILD_PROP" || abort "Failed to update native bridge to libnb.so"
        fi
    fi
    
    echo "libhoudini installation completed"
}

# Function to finalize images (unmount, check, resize, convert back to vhdx)
finalize_wsa_images() {
    echo "=== Finalizing WSA Images ==="
    
    # Unmount images
    echo "Unmounting images..."
    sudo umount "$MOUNT_BASE/system" || abort "Failed to unmount system"
    sudo umount "$MOUNT_BASE/vendor" || abort "Failed to unmount vendor"
    
    # Check and fix filesystems
    echo "Checking system filesystem..."
    e2fsck -yf "$WSA_PATH/system.img" || abort "Failed to check system filesystem"
    
    echo "Checking vendor filesystem..."
    e2fsck -yf "$WSA_PATH/vendor.img" || abort "Failed to check vendor filesystem"
    
    # Minimize filesystems to optimal size
    echo "Minimizing system.img to optimal size..."
    resize2fs -M "$WSA_PATH/system.img" || abort "Failed to minimize system.img"
    
    echo "Minimizing vendor.img to optimal size..."
    resize2fs -M "$WSA_PATH/vendor.img" || abort "Failed to minimize vendor.img"
    
    # Convert back to vhdx format
    echo "Converting system.img back to vhdx format..."
    qemu-img convert -f raw -O vhdx "$WSA_PATH/system.img" "$WSA_PATH/system.vhdx" || abort "Failed to convert system.img to vhdx"
    
    echo "Converting vendor.img back to vhdx format..."
    qemu-img convert -f raw -O vhdx "$WSA_PATH/vendor.img" "$WSA_PATH/vendor.vhdx" || abort "Failed to convert vendor.img to vhdx"
    
    # Remove temporary img files
    echo "Removing temporary img files..."
    rm -f "$WSA_PATH/system.img" "$WSA_PATH/vendor.img" || true
    
    echo "Images finalized successfully"
}

# Function to create archive if requested
create_archive() {
    if [ -n "$ARCHIVE_NAME" ]; then
        echo "=== Creating Archive ==="
        cd "$DIRECTORY" || abort "Failed to change to directory"
        
        echo "Creating 7z archive with highest compression: $ARCHIVE_NAME.7z"
        7z a -t7z -m0=lzma2 -mx=9 -mfb=64 -md=32m -ms=on "$ARCHIVE_NAME.7z" "$ARM_SOURCE" || abort "Failed to create archive"
        
        echo "Archive created successfully: $DIRECTORY/$ARCHIVE_NAME.7z"
        
        # Clean up working directory
        echo "Cleaning up working directory..."
        rm -rf "$WSA_PATH" || true
    fi
}

# Function to set file timestamps
set_file_timestamps() {
    echo "Setting timestamps for all files..."
    sudo find "$MOUNT_BASE/vendor" -exec touch -hamt 200901010000.00 {} \; 2>/dev/null || echo "Warning: Failed to set timestamps for some vendor files"
    sudo find "$MOUNT_BASE/system" -exec touch -hamt 200901010000.00 {} \; 2>/dev/null || echo "Warning: Failed to set timestamps for some system files"
}

# Main execution
echo "=== Starting WSA ARM Translation Installation ==="

# Process VHDX images to mountable IMG format
process_wsa_images

# Install ARM translation layer
install_arm_translation

# Set file timestamps
set_file_timestamps

# Finalize images
finalize_wsa_images

# Create archive if requested
create_archive

# Clean up mount base directory
sudo rm -rf "$MOUNT_BASE" 2>/dev/null || true

# Remove trap since we're done
trap - EXIT

echo "=== Installation Complete ==="
echo "WSA ARM translation installation completed successfully!"
echo "Type: $ARM_TYPE"
echo "Source: $ARM_SOURCE"
echo "Processed images are available at: $WSA_PATH"

if [ -n "$ARCHIVE_NAME" ]; then
    echo "Archive created: $DIRECTORY/$ARCHIVE_NAME.7z"
fi
