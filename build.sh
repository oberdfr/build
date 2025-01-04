#!/bin/bash

# Exit on error
set -e

# Default values
ROOT_DIR=$(pwd)
JOBS=$(nproc)
OUT_DIR="$ROOT_DIR/out"
DIST_DIR="$ROOT_DIR/dist"
KERNEL_DIR="$ROOT_DIR/kernel"
DT_CONFIGS="$ROOT_DIR/dt-configs"
FSTAB_DIR="$ROOT_DIR/fstab"

MKDTIMG="$ROOT_DIR/mkdtimg/mkdtimg"
MKBOOTIMG="python3 $ROOT_DIR/mkbootimg/mkbootimg.py"
AVBTOOL="python3 $ROOT_DIR/external_avb/avbtool.py"
FSTAB_FILE="$ROOT_DIR/fstab/fstab.exynos2100"
FIRST_STAGE_FSTAB_FILE="$ROOT_DIR/fstab/first_stage-fstab.exynos2100"

DEVICE="o1s"  # Default device
ARCH="arm64"
DEFCONFIG="exynos2100-${DEVICE}xxx_defconfig"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Display help
show_help() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -j    Number of jobs (default: number of CPU cores)"
    echo "  -d    Device (o1s, p3s, t2s)"
    echo "  -o    Output directory (default: out)"
    echo "  -h    Show this help message"
    exit 0
}

generate_salt() {
    head -c 32 /dev/urandom | xxd -p -c 32
}

# Parse command line arguments
while getopts "j:d:o:h" opt; do
    case $opt in
        j) JOBS="$OPTARG" ;;
        d) DEVICE="$OPTARG" ;;
        o) OUT_DIR="$OPTARG" ;;
        h) show_help ;;
        ?) show_help ;;
    esac
done

# Print build configuration
echo -e "${GREEN}Building kernel with the following configuration:${NC}"
echo -e "Jobs: ${YELLOW}$JOBS${NC}"
echo -e "Device: ${YELLOW}$DEVICE${NC}"
echo -e "Dist directory: ${YELLOW}$DIST_DIR${NC}"
echo -e "Output directory: ${YELLOW}$OUT_DIR${NC}"

# Export necessary variables
export ARCH=arm64
export PLATFORM_VERSION=11
export ANDROID_MAJOR_VERSION=r
export SEC_BUILD_CONF_VENDOR_BUILD_OS=13

# Toolchain configuration
export CC=clang
export LD=ld.lld
export LLVM=1
export LLVM_IAS=1
export CLANG_TRIPLE=aarch64-linux-gnu-
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

# Create necessary directories
mkdir -p "$OUT_DIR"

# Signing variables
GKI_SIGNING_KEY="$ROOT_DIR/keys/private_key.pem"
GKI_SIGNING_ALGORITHM="SHA256_RSA4096"
GKI_SIGNING_AVBTOOL="$AVBTOOL"

# Ensure signing key exists
if [ ! -f "$GKI_SIGNING_KEY" ]; then
    echo -e "${RED}Error: GKI signing key not found: $GKI_SIGNING_KEY${NC}"
    exit 1
fi

# Function to sign images
sign_image() {
    local image_path=$1
    local partition_name=$2
    local partition_size=$3

    if [ -f "$image_path" ]; then
        echo -e "${YELLOW}Signing $partition_name using AVB...${NC}"
        $GKI_SIGNING_AVBTOOL add_hash_footer \
            --image "$image_path" \
            --partition_name "$partition_name" \
            --partition_size "$partition_size" \
            --key "$GKI_SIGNING_KEY" \
            --algorithm "$GKI_SIGNING_ALGORITHM"

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}$partition_name successfully signed!${NC}"
        else
            echo -e "${RED}Error: Failed to sign $partition_name.${NC}"
            exit 1
        fi
    else
        echo -e "${RED}Error: $partition_name image not found: $image_path${NC}"
        exit 1
    fi
}

# Build steps
echo -e "\n${GREEN}Building kernel...${NC}"

# Check for avbtool
if ! command -v $AVBTOOL &> /dev/null; then
    echo -e "${RED}Error: avbtool is not installed.${NC}"
    exit 1
fi

# Check for keys
if [ ! -f "$ROOT_DIR/keys/private_key.pem" ] || [ ! -f "$ROOT_DIR/keys/public_key_metadata.bin" ]; then
    echo -e "${RED}Error: Keys not found in $ROOT_DIR/keys.${NC}"
    exit 1
fi

# --- BUILD KERNEL --- #
cd $KERNEL_DIR
# 1. Generate defconfig
echo -e "${YELLOW}Generating defconfig...${NC}"
# make O="$OUT_DIR" ARCH="$ARCH" "$DEFCONFIG"

# 2. Build kernel
echo -e "${YELLOW}Building kernel image...${NC}"
# make O="$OUT_DIR" ARCH="$ARCH" -j"$JOBS"

cd $ROOT_DIR
# --- BUILD KERNEL END --- #

# 3. Build DTBO image
echo -e "${YELLOW}Building DTBO image...${NC}"
if [ -f "$MKDTIMG" ]; then
    mkdir -p "$DIST_DIR/dtbo"
    find "$OUT_DIR/arch/$ARCH/boot/dts/samsung/$DEVICE" -name "*.dtbo" -exec cp {} "$DIST_DIR/dtbo/" \;
    
    if [ -f "$DT_CONFIGS/$DEVICE.cfg" ]; then
        "${MKDTIMG}" cfg_create "$DIST_DIR/dtbo.img" \
            $DT_CONFIGS/$DEVICE.cfg \
            -d "$DIST_DIR/dtbo"
        echo -e "${GREEN}DTBO image created successfully${NC}"
    else
        echo -e "${RED}Error: Device config file not found: $DT_CONFIGS/$DEVICE.cfg${NC}"
        exit 1
    fi
else
    echo -e "${RED}Error: mkdtimg tool not found${NC}"
    exit 1
fi

# 4. Build DTB image
echo -e "${YELLOW}Building DTB image...${NC}"
if [ -f "$DT_CONFIGS/exynos2100.cfg" ]; then
    mkdir -p "$DIST_DIR/dtb"
    find "$OUT_DIR/arch/$ARCH/boot/dts/exynos" -name "*.dtb" -exec cp {} "$DIST_DIR/dtb/" \;
    "${MKDTIMG}" cfg_create "$DIST_DIR/dtb.img" \
        $DT_CONFIGS/exynos2100.cfg \
        -d "$DIST_DIR/dtb"
    echo -e "${GREEN}DTB image created successfully${NC}"
else
    echo -e "${RED}Error: Exynos DTB config file not found${NC}"
    exit 1
fi

# 5. Create boot.img
echo -e "${YELLOW}Creating boot.img...${NC}"
$MKBOOTIMG \
    --kernel "$OUT_DIR/arch/$ARCH/boot/Image" \
    --pagesize 4096 \
    --base 0x00000000 \
    --kernel_offset 0x80008000 \
    --header_version 3 \
    --os_version 15.0.0 \
    --os_patch_level 2024-11 \
    -o "$DIST_DIR/boot.img"


# Copy vendor_boot modules
input_dir=$OUT_DIR
output_dir="$DIST_DIR/lib/modules"
mkdir -p "$output_dir"

cd $KERNEL_DIR
while read -r line; do

    filename=$(basename "$line")
    cp "$input_dir/$line" "$output_dir/$filename"
    aarch64-linux-gnu-strip --strip-debug "$output_dir/$filename"

done < <(awk '/^drivers\//{print $1}' < $OUT_DIR/modules.order)


cd $ROOT_DIR

# Process kernel modules for vendor ramdisk
if [ -d "$DIST_DIR/lib/modules" ]; then
    echo -e "${YELLOW}Processing kernel modules for vendor ramdisk...${NC}"
    # Create temporary directory for vendor ramdisk
    TEMP_VENDOR_RAMDISK="$DIST_DIR/temp_vendor_ramdisk"
    mkdir -p "$TEMP_VENDOR_RAMDISK/lib/modules"
    
    # Copy modules to ramdisk
    cp -r "$DIST_DIR/lib/modules"/* "$TEMP_VENDOR_RAMDISK/lib/modules/"

    # Copy fstab file to vendor ramdisk
    if [ -f $FSTAB_FILE ]; then
        cp $FSTAB_FILE "$TEMP_VENDOR_RAMDISK/"
    else
        echo -e "${RED}Error: fstab.exynos2100 not found in stock ramdisk.${NC}"
        exit 1
    fi

    # Add first stage ramdisk to vendor ramdisk
    if [ -f $FIRST_STAGE_FSTAB_FILE ]; then
        mkdir -p "$TEMP_VENDOR_RAMDISK/first_stage_ramdisk"
        cp -r $FIRST_STAGE_FSTAB_FILE "$TEMP_VENDOR_RAMDISK/first_stage_ramdisk/fstab.exynos2100"
    else
        echo -e "${YELLOW}Warning: First stage ramdisk folder not found in stock ramdisk. Proceeding without it.${NC}"
    fi

    # Copy firmware to vendor ramdisk
    if [ -d "$ROOT_DIR/vendor" ]; then
        mkdir -p "$TEMP_VENDOR_RAMDISK/first_stage_ramdisk"
        cp -r "$ROOT_DIR/vendor" "$TEMP_VENDOR_RAMDISK/"
    else
        echo -e "${YELLOW}Warning: Vendor folder not found in stock ramdisk. Proceeding without it.${NC}"
    fi

    # Create vendor ramdisk cpio
    (cd "$TEMP_VENDOR_RAMDISK" && \
        find . | cpio -H newc -o | gzip > "$DIST_DIR/vendor_ramdisk.cpio.gz" && \
        cd - > /dev/null)
        
    # Add vendor ramdisk to vendor_boot
    $MKBOOTIMG \
            --kernel "$OUT_DIR/arch/$ARCH/boot/Image" \
            --dtb "$DIST_DIR/dtb.img" \
            --pagesize 4096 \
            --board "SRPTH19C005KU" \
            --base 0x00000000 \
            --kernel_offset 0x80008000 \
            --ramdisk_offset 0x84000000 \
            --dtb_offset 0x81F00000 \
            --tags_offset 0x80000000 \
            --header_version 3 \
            --vendor_ramdisk "$DIST_DIR/vendor_ramdisk.cpio.gz" \
            --vendor_boot "$DIST_DIR/vendor_boot.img"
    
    rm -rf "$TEMP_VENDOR_RAMDISK"
fi

# Sign boot.img
sign_image "$DIST_DIR/boot.img" "boot" "67108864"

# Sign vendor_boot.img
sign_image "$DIST_DIR/vendor_boot.img" "vendor_boot" "67108864"  # Adjust partition 

# Check if all required files exist
if [ -f "$DIST_DIR/boot.img" ] && [ -f "$DIST_DIR/dtbo.img" ] && [ -f "$DIST_DIR/vendor_boot.img" ]; then
    echo -e "\n${GREEN}Build completed successfully!${NC}"
    echo -e "Output files:"
    echo -e "  - Boot image: ${YELLOW}$DIST_DIR/boot.img${NC}"
    echo -e "  - DTBO image: ${YELLOW}$DIST_DIR/dtbo.img${NC}"
    echo -e "  - DTB image: ${YELLOW}$DIST_DIR/dtb.img${NC}"
    echo -e "  - Vendor boot image: ${YELLOW}$DIST_DIR/vendor_boot.img${NC}"
else
    echo -e "\n${RED}Build failed: Some output files are missing${NC}"
    exit 1
fi