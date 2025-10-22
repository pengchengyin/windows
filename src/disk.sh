#!/usr/bin/env bash
set -Eeuo pipefail

# Overlay 磁盘功能
# 支持基于已有 data.img 文件的 overlay 磁盘

# 检查是否存在基础磁盘文件
checkBaseDisk() {
  local base_disk="$1"
  
  if [ -f "$base_disk" ] && [ -s "$base_disk" ]; then
    info "Found existing base disk: $base_disk"
    return 0
  fi
  
  return 1
}

# 创建 overlay 磁盘文件
createOverlayDisk() {
  local base_disk="$1"
  local overlay_disk="$2"
  
  if [ -f "$overlay_disk" ]; then
    info "Overlay disk already exists: $overlay_disk"
    return 0
  fi
  
  local msg="Creating overlay disk..."
  info "$msg" && html "$msg"
  
  # 获取基础磁盘的文件扩展名并确定格式
  local base_ext
  base_ext=$(echo "${base_disk//*./}" | sed 's/^.*\.//')
  
  # 确定基础磁盘格式
  local base_fmt
  case "${base_ext,,}" in
    qcow2)
      base_fmt="qcow2"
      ;;
    img|raw)
      base_fmt="raw"
      ;;
    *)
      # 如果无法确定格式，尝试让 qemu-img 自动检测
      info "Unable to determine base disk format from extension, trying auto-detection..."
      # 使用 qemu-img info 来获取格式信息
      base_fmt=$(qemu-img info --output=json "$base_disk" | grep -o '"format": "[^"]*"' | cut -d'"' -f4)
      if [ -z "$base_fmt" ]; then
        # 如果自动检测失败，默认为 raw
        info "Auto-detection failed, defaulting to raw format"
        base_fmt="raw"
      else
        info "Detected base disk format: $base_fmt"
      fi
      ;;
  esac
  
  # 使用 qemu-img 创建 overlay 磁盘，指定基础磁盘格式
  if ! qemu-img create -f qcow2 -b "$base_disk" -F "$base_fmt" "$overlay_disk"; then
    error "Failed to create overlay disk: $overlay_disk"
    return 1
  fi
  
  # 验证文件是否真的创建成功
  if [ ! -f "$overlay_disk" ]; then
    error "Overlay disk file was not found after creation: $overlay_disk"
    # 尝试使用绝对路径再创建一次
    info "Attempting to create overlay disk with absolute path..."
    if ! qemu-img create -f qcow2 -b "$base_disk" -F "$base_fmt" "/storage/data-overlay.qcow2"; then
      error "Failed to create overlay disk with absolute path"
      return 1
    fi
    overlay_disk="/storage/data-overlay.qcow2"
  fi
  
  info "Overlay disk created successfully: $overlay_disk"
  return 0
}

# 初始化 overlay 磁盘
initOverlayDisk() {
  local base_disk=""
  local overlay_disk="$STORAGE/data-overlay.qcow2"
  
  info "Initializing overlay disk..."
  
  # 检查是否存在基础磁盘文件
  if [ -f "$STORAGE/data.img" ] && [ -s "$STORAGE/data.img" ]; then
    base_disk="$STORAGE/data.img"
    info "Found base disk: $base_disk"
  elif [ -f "$STORAGE/data.qcow2" ] && [ -s "$STORAGE/data.qcow2" ]; then
    base_disk="$STORAGE/data.qcow2"
    info "Found base disk: $base_disk"
  else
    error "No base disk found in $STORAGE"
    return 1
  fi
  
  info "Base disk path: $base_disk"
  info "Overlay disk path: $overlay_disk"
  
  # 检查是否存在基础磁盘
  if checkBaseDisk "$base_disk"; then
    # 基于已有磁盘创建 overlay 磁盘
    if ! createOverlayDisk "$base_disk" "$overlay_disk"; then
      error "Failed to create overlay disk based on existing base disk"
      return 1
    fi
    
    # 设置环境变量
    export BASE_DISK="$base_disk"
    export OVERLAY_DISK="$overlay_disk"
    
    info "Using existing base disk with overlay: $overlay_disk"
    return 0
  fi
  
  error "Base disk not found or invalid: $base_disk"
  return 1
}

# 获取磁盘文件路径（支持 overlay）
getDiskPath() {
  if [ -n "${OVERLAY_DISK:-}" ] && [ -f "$OVERLAY_DISK" ]; then
    echo "$OVERLAY_DISK"
  elif [ -n "${BASE_DISK:-}" ] && [ -f "$BASE_DISK" ]; then
    echo "$BASE_DISK"
  else
    echo "$STORAGE/data.img"
  fi
}

# 清理 overlay 磁盘
cleanOverlayDisk() {
  local overlay_disk="$STORAGE/data-overlay.qcow2"
  
  if [ -f "$overlay_disk" ]; then
    local msg="Cleaning overlay disk..."
    info "$msg" && html "$msg"
    
    rm -f "$overlay_disk"
    info "Overlay disk cleaned: $overlay_disk"
  fi
}

# 合并 overlay 磁盘到基础磁盘
mergeOverlayDisk() {
  local base_disk="$STORAGE/data.img"
  local overlay_disk="$STORAGE/data-overlay.qcow2"
  
  if [ ! -f "$overlay_disk" ]; then
    return 0
  fi
  
  local msg="Merging overlay disk to base disk..."
  info "$msg" && html "$msg"
  
  # 使用 qemu-img 合并 overlay 到基础磁盘
  if ! qemu-img commit "$overlay_disk"; then
    error "Failed to merge overlay disk to base disk"
    return 1
  fi
  
  # 清理 overlay 磁盘
  cleanOverlayDisk
  
  info "Overlay disk merged successfully to base disk"
  return 0
}

# 检查是否应该使用 overlay 磁盘
shouldUseOverlay() {
  # 检查环境变量
  if [[ "${USE_OVERLAY:-}" == [Yy1]* ]]; then
    info "USE_OVERLAY environment variable is set, enabling overlay mode"
    return 0
  fi
  
  # 如果存在 data.img 或 data.qcow2 文件，则使用 overlay
  if [ -f "$STORAGE/data.img" ] && [ -s "$STORAGE/data.img" ]; then
    info "Found existing data.img file, enabling overlay mode"
    return 0
  fi
  
  if [ -f "$STORAGE/data.qcow2" ] && [ -s "$STORAGE/data.qcow2" ]; then
    info "Found existing data.qcow2 file, enabling overlay mode"
    return 0
  fi
  
  info "No existing data disk found, using normal disk creation"
  return 1
}

# Docker environment variables

: "${DISK_IO:="native"}"          # I/O Mode, can be set to 'native', 'threads' or 'io_uring'
: "${DISK_FMT:=""}"               # Disk file format, can be set to "raw" (default) or "qcow2"
: "${DISK_TYPE:=""}"              # Device type to be used, "sata", "nvme", "blk" or "scsi"
: "${DISK_FLAGS:=""}"             # Specifies the options for use with the qcow2 disk format
: "${DISK_CACHE:="none"}"         # Caching mode, can be set to 'writeback' for better performance
: "${DISK_DISCARD:="on"}"         # Controls whether unmap (TRIM) commands are passed to the host.
: "${DISK_ROTATION:="1"}"         # Rotation rate, set to 1 for SSD storage and increase for HDD

fmt2ext() {
  local DISK_FMT="$1"

  case "${DISK_FMT,,}" in
    qcow2)
      echo "qcow2"
      ;;
    raw)
      echo "img"
      ;;
    *)
      error "Unrecognized disk format: $DISK_FMT" && exit 78
      ;;
  esac
}

ext2fmt() {
  local DISK_EXT="$1"

  case "${DISK_EXT,,}" in
    qcow2)
      echo "qcow2"
      ;;
    img)
      echo "raw"
      ;;
    *)
      error "Unrecognized file extension: .$DISK_EXT" && exit 78
      ;;
  esac
}

getSize() {
  local DISK_FILE="$1"
  local DISK_EXT DISK_FMT

  DISK_EXT=$(echo "${DISK_FILE//*./}" | sed 's/^.*\.//')
  DISK_FMT=$(ext2fmt "$DISK_EXT")

  case "${DISK_FMT,,}" in
    raw)
      stat -c%s "$DISK_FILE"
      ;;
    qcow2)
      qemu-img info "$DISK_FILE" -f "$DISK_FMT" | grep '^virtual size: ' | sed 's/.*(\(.*\) bytes)/\1/'
      ;;
    *)
      error "Unrecognized disk format: $DISK_FMT" && exit 78
      ;;
  esac
}

isCow() {
  local FS="$1"

  if [[ "${FS,,}" == "btrfs" ]]; then
    return 0
  fi

  return 1
}

supportsDirect() {
  local FS="$1"

  if [[ "${FS,,}" == "ecryptfs" || "${FS,,}" == "tmpfs" ]]; then
    return 1
  fi

  return 0
}

createDisk() {

  local DISK_FILE="$1"
  local DISK_SPACE="$2"
  local DISK_DESC="$3"
  local DISK_FMT="$4"
  local FS="$5"
  local DATA_SIZE DIR SPACE GB FA

  rm -f "$DISK_FILE"

  DATA_SIZE=$(numfmt --from=iec "$DISK_SPACE")

  if [[ "$ALLOCATE" != [Nn]* ]]; then

    # Check free diskspace
    DIR=$(dirname "$DISK_FILE")
    SPACE=$(df --output=avail -B 1 "$DIR" | tail -n 1)

    if (( DATA_SIZE > SPACE )); then
      GB=$(formatBytes "$SPACE")
      error "Not enough free space to create a $DISK_DESC of ${DISK_SPACE/G/ GB} in $DIR, it has only $GB available..."
      error "Please specify a smaller ${DISK_DESC^^}_SIZE or disable preallocation by setting ALLOCATE=N." && exit 76
    fi

  fi

  html "Creating a $DISK_DESC image..."
  info "Creating a ${DISK_SPACE/G/ GB} $DISK_STYLE $DISK_DESC image in $DISK_FMT format..."

  local FAIL="Could not create a $DISK_STYLE $DISK_FMT $DISK_DESC image of ${DISK_SPACE/G/ GB} ($DISK_FILE)"

  case "${DISK_FMT,,}" in
    raw)

      if isCow "$FS"; then
        if ! touch "$DISK_FILE"; then
          error "$FAIL" && exit 77
        fi
        { chattr +C "$DISK_FILE"; } || :
      fi

      if [[ "$ALLOCATE" == [Nn]* ]]; then

        # Create an empty file
        if ! truncate -s "$DATA_SIZE" "$DISK_FILE"; then
          rm -f "$DISK_FILE"
          error "$FAIL" && exit 77
        fi

      else

        # Create an empty file
        if ! fallocate -l "$DATA_SIZE" "$DISK_FILE" &>/dev/null; then
          if ! fallocate -l -x "$DATA_SIZE" "$DISK_FILE"; then
            if ! truncate -s "$DATA_SIZE" "$DISK_FILE"; then
              rm -f "$DISK_FILE"
              error "$FAIL" && exit 77
            fi
          fi
        fi

      fi
      ;;
    qcow2)

      local DISK_PARAM="$DISK_ALLOC"
      isCow "$FS" && DISK_PARAM+=",nocow=on"
      [ -n "$DISK_FLAGS" ] && DISK_PARAM+=",$DISK_FLAGS"

      if ! qemu-img create -f "$DISK_FMT" -o "$DISK_PARAM" -- "$DISK_FILE" "$DATA_SIZE" ; then
        rm -f "$DISK_FILE"
        error "$FAIL" && exit 70
      fi
      ;;
  esac

  if isCow "$FS"; then
    FA=$(lsattr "$DISK_FILE")
    if [[ "$FA" != *"C"* ]]; then
      error "Failed to disable COW for $DISK_DESC image $DISK_FILE on ${FS^^} filesystem (returned $FA)"
    fi
  fi

  return 0
}

resizeDisk() {

  local DISK_FILE="$1"
  local DISK_SPACE="$2"
  local DISK_DESC="$3"
  local DISK_FMT="$4"
  local FS="$5"
  local CUR_SIZE DATA_SIZE DIR SPACE GB

  CUR_SIZE=$(getSize "$DISK_FILE")
  DATA_SIZE=$(numfmt --from=iec "$DISK_SPACE")
  local REQ=$(( DATA_SIZE - CUR_SIZE ))
  (( REQ < 1 )) && error "Shrinking disks is not supported yet, please increase ${DISK_DESC^^}_SIZE." && exit 71

  if [[ "$ALLOCATE" != [Nn]* ]]; then

    # Check free diskspace
    DIR=$(dirname "$DISK_FILE")
    SPACE=$(df --output=avail -B 1 "$DIR" | tail -n 1)

    if (( REQ > SPACE )); then
      GB=$(formatBytes "$SPACE")
      error "Not enough free space to resize $DISK_DESC to ${DISK_SPACE/G/ GB} in $DIR, it has only $GB available.."
      error "Please specify a smaller ${DISK_DESC^^}_SIZE or disable preallocation by setting ALLOCATE=N." && exit 74
    fi

  fi

  GB=$(formatBytes "$CUR_SIZE")
  MSG="Resizing $DISK_DESC from $GB to ${DISK_SPACE/G/ GB}..."
  info "$MSG" && html "$MSG"

  local FAIL="Could not resize the $DISK_STYLE $DISK_FMT $DISK_DESC image from ${GB} to ${DISK_SPACE/G/ GB} ($DISK_FILE)"

  case "${DISK_FMT,,}" in
    raw)

      if [[ "$ALLOCATE" == [Nn]* ]]; then

        # Resize file by changing its length
        if ! truncate -s "$DATA_SIZE" "$DISK_FILE"; then
          error "$FAIL" && exit 75
        fi

      else

        # Resize file by allocating more space
        if ! fallocate -l "$DATA_SIZE" "$DISK_FILE" &>/dev/null; then
          if ! fallocate -l -x "$DATA_SIZE" "$DISK_FILE"; then
            if ! truncate -s "$DATA_SIZE" "$DISK_FILE"; then
              error "$FAIL" && exit 75
            fi
          fi
        fi

      fi
      ;;
    qcow2)

      if ! qemu-img resize -f "$DISK_FMT" "--$DISK_ALLOC" "$DISK_FILE" "$DATA_SIZE" ; then
        error "$FAIL" && exit 72
      fi

      ;;
  esac

  return 0
}

convertDisk() {

  local SOURCE_FILE="$1"
  local SOURCE_FMT="$2"
  local DST_FILE="$3"
  local DST_FMT="$4"
  local DISK_BASE="$5"
  local DISK_DESC="$6"
  local FS="$7"

  [ -f "$DST_FILE" ] && error "Conversion failed, destination file $DST_FILE already exists?" && exit 79
  [ ! -f "$SOURCE_FILE" ] && error "Conversion failed, source file $SOURCE_FILE does not exists?" && exit 79

  local TMP_FILE="$DISK_BASE.tmp"
  rm -f "$TMP_FILE"

  if [[ "$ALLOCATE" != [Nn]* ]]; then

    local DIR CUR_SIZE SPACE GB

    # Check free diskspace
    DIR=$(dirname "$TMP_FILE")
    CUR_SIZE=$(getSize "$SOURCE_FILE")
    SPACE=$(df --output=avail -B 1 "$DIR" | tail -n 1)

    if (( CUR_SIZE > SPACE )); then
      GB=$(formatBytes "$SPACE")
      error "Not enough free space to convert $DISK_DESC to $DST_FMT in $DIR, it has only $GB available..."
      error "Please free up some disk space or disable preallocation by setting ALLOCATE=N." && exit 76
    fi

  fi

  local msg="Converting $DISK_DESC to $DST_FMT"
  html "$msg..."
  info "$msg, please wait until completed..."

  local CONV_FLAGS="-p"
  local DISK_PARAM="$DISK_ALLOC"
  isCow "$FS" && DISK_PARAM+=",nocow=on"

  if [[ "$DST_FMT" != "raw" ]]; then
    if [[ "$ALLOCATE" == [Nn]* ]]; then
      CONV_FLAGS+=" -c"
    fi
    [ -n "$DISK_FLAGS" ] && DISK_PARAM+=",$DISK_FLAGS"
  fi

  # shellcheck disable=SC2086
  if ! qemu-img convert -f "$SOURCE_FMT" $CONV_FLAGS -o "$DISK_PARAM" -O "$DST_FMT" -- "$SOURCE_FILE" "$TMP_FILE"; then
    rm -f "$TMP_FILE"
    error "Failed to convert $DISK_STYLE $DISK_DESC image to $DST_FMT format in $DIR, is there enough space available?" && exit 79
  fi

  if [[ "$DST_FMT" == "raw" ]]; then
    if [[ "$ALLOCATE" != [Nn]* ]]; then
      # Work around qemu-img bug
      CUR_SIZE=$(stat -c%s "$TMP_FILE")
      if ! fallocate -l "$CUR_SIZE" "$TMP_FILE" &>/dev/null; then
        if ! fallocate -l -x "$CUR_SIZE" "$TMP_FILE"; then
          error "Failed to allocate $CUR_SIZE bytes for $DISK_DESC image $TMP_FILE"
        fi
      fi
    fi
  fi

  rm -f "$SOURCE_FILE"
  mv "$TMP_FILE" "$DST_FILE"

  if isCow "$FS"; then
    FA=$(lsattr "$DST_FILE")
    if [[ "$FA" != *"C"* ]]; then
      error "Failed to disable COW for $DISK_DESC image $DST_FILE on ${FS^^} filesystem (returned $FA)"
    fi
  fi

  msg="Conversion of $DISK_DESC"
  html "$msg completed..."
  info "$msg to $DST_FMT completed successfully!"

  return 0
}

checkFS () {

  local FS="$1"
  local DISK_FILE="$2"
  local DISK_DESC="$3"
  local DIR FA

  DIR=$(dirname "$DISK_FILE")
  [ ! -d "$DIR" ] && return 0

  if [[ "${FS,,}" == "overlay"* ]]; then
    info "Warning: the filesystem of $DIR is OverlayFS, this usually means it was binded to an invalid path!"
  fi

  if [[ "${FS,,}" == "fuse"* ]]; then
    info "Warning: the filesystem of $DIR is FUSE, this extra layer will negatively affect performance!"
  fi

  if ! supportsDirect "$FS"; then
    info "Warning: the filesystem of $DIR is $FS, which does not support O_DIRECT mode, adjusting settings..."
  fi

  if isCow "$FS"; then
    if [ -f "$DISK_FILE" ]; then
      FA=$(lsattr "$DISK_FILE")
      if [[ "$FA" != *"C"* ]]; then
        info "Warning: COW (copy on write) is not disabled for $DISK_DESC image file $DISK_FILE, this is recommended on ${FS^^} filesystems!"
      fi
    fi
  fi

  return 0
}

createDevice () {

  local DISK_FILE="$1"
  local DISK_TYPE="$2"
  local DISK_INDEX="$3"
  local DISK_ADDRESS="$4"
  local DISK_FMT="$5"
  local DISK_IO="$6"
  local DISK_CACHE="$7"
  local DISK_SERIAL="$8"
  local DISK_SECTORS="$9"
  local DISK_ID="data$DISK_INDEX"

  local index=""
  [ -n "$DISK_INDEX" ] && index=",bootindex=$DISK_INDEX"
  local result=" -drive file=$DISK_FILE,id=$DISK_ID,format=$DISK_FMT,cache=$DISK_CACHE,aio=$DISK_IO,discard=$DISK_DISCARD,detect-zeroes=on"

  case "${DISK_TYPE,,}" in
    "none" ) ;;
    "auto" )
      echo "$result"
      ;;
    "usb" )
      result+=",if=none \
      -device usb-storage,drive=${DISK_ID}${index}${DISK_SERIAL}${DISK_SECTORS}"
      echo "$result"
      ;;
    "nvme" )
      result+=",if=none \
      -device nvme,drive=${DISK_ID}${index},serial=deadbeaf${DISK_INDEX}${DISK_SERIAL}${DISK_SECTORS}"
      echo "$result"
      ;;
    "ide" | "sata" )
      result+=",if=none \
      -device ich9-ahci,id=ahci${DISK_INDEX},addr=$DISK_ADDRESS \
      -device ide-hd,drive=${DISK_ID},bus=ahci$DISK_INDEX.0,rotation_rate=$DISK_ROTATION${index}${DISK_SERIAL}${DISK_SECTORS}"
      echo "$result"
      ;;
    "blk" | "virtio-blk" )
      result+=",if=none \
      -device virtio-blk-pci,drive=${DISK_ID},bus=pcie.0,addr=$DISK_ADDRESS,iothread=io2${index}${DISK_SERIAL}${DISK_SECTORS}"
      echo "$result"
      ;;
    "scsi" | "virtio-scsi" )
      result+=",if=none \
      -device virtio-scsi-pci,id=${DISK_ID}b,bus=pcie.0,addr=$DISK_ADDRESS,iothread=io2 \
      -device scsi-hd,drive=${DISK_ID},bus=${DISK_ID}b.0,channel=0,scsi-id=0,lun=0,rotation_rate=$DISK_ROTATION${index}${DISK_SERIAL}${DISK_SECTORS}"
      echo "$result"
      ;;
  esac

  return 0
}

addMedia () {

  local DISK_FILE="$1"
  local DISK_TYPE="$2"
  local DISK_INDEX="$3"
  local DISK_ADDRESS="$4"

  local index=""
  local DISK_ID="cdrom$DISK_INDEX"
  [ -n "$DISK_INDEX" ] && index=",bootindex=$DISK_INDEX"
  local result=" -drive file=$DISK_FILE,id=$DISK_ID,format=raw,cache=unsafe,readonly=on,media=cdrom"

  case "${DISK_TYPE,,}" in
    "none" ) ;;
    "auto" )
      echo "$result"
      ;;
    "usb" )
      result+=",if=none \
      -device usb-storage,drive=${DISK_ID}${index},removable=on"
      echo "$result"
      ;;
    "nvme" )
      result+=",if=none \
      -device nvme,drive=${DISK_ID}${index},serial=deadbeaf${DISK_INDEX}"
      echo "$result"
      ;;
    "ide" | "sata" )
      result+=",if=none \
      -device ich9-ahci,id=ahci${DISK_INDEX},addr=$DISK_ADDRESS \
      -device ide-cd,drive=${DISK_ID},bus=ahci${DISK_INDEX}.0${index}"
      echo "$result"
      ;;
    "blk" | "virtio-blk" )
      result+=",if=none \
      -device virtio-blk-pci,drive=${DISK_ID},bus=pcie.0,addr=$DISK_ADDRESS,iothread=io2${index}"
      echo "$result"
      ;;
    "scsi" | "virtio-scsi" )
      result+=",if=none \
      -device virtio-scsi-pci,id=${DISK_ID}b,bus=pcie.0,addr=$DISK_ADDRESS,iothread=io2 \
      -device scsi-cd,drive=${DISK_ID},bus=${DISK_ID}b.0${index}"
      echo "$result"
      ;;
  esac

  return 0
}

addDisk () {

  local DISK_BASE="$1"
  local DISK_TYPE="$2"
  local DISK_DESC="$3"
  local DISK_SPACE="$4"
  local DISK_INDEX="$5"
  local DISK_ADDRESS="$6"
  local DISK_FMT="$7"
  local DISK_IO="$8"
  local DISK_CACHE="$9"
  local DISK_EXT DIR SPACE GB DATA_SIZE FS PREV_FMT PREV_EXT CUR_SIZE LEFT FREE USED

  DISK_EXT=$(fmt2ext "$DISK_FMT")
  local DISK_FILE="$DISK_BASE.$DISK_EXT"

  DIR=$(dirname "$DISK_FILE")
  [ ! -d "$DIR" ] && return 0

  if [[ "${DISK_SPACE,,}" == "max" || "${DISK_SPACE,,}" == "half" ]]; then

    local SPARE=1073741824
    FREE=$(df --output=avail -B 1 "$DIR" | tail -n 1)

    if [[ "${DISK_SPACE,,}" == "max" ]]; then
      FREE=$(( FREE - SPARE ))
    else
      FREE=$(( FREE / 2 ))
    fi

    (( FREE < SPARE )) && FREE="$SPARE"
    GB=$(( FREE / 1073741825 ))
    DISK_SPACE="${GB}G"

  fi

  SPACE="${DISK_SPACE// /}"
  [ -z "$SPACE" ] && SPACE="64G"
  [ -z "${SPACE//[0-9. ]}" ] && SPACE="${SPACE}G"
  SPACE=$(echo "${SPACE^^}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')

  if ! numfmt --from=iec "$SPACE" &>/dev/null; then
    error "Invalid value for ${DISK_DESC^^}_SIZE: $DISK_SPACE" && exit 73
  fi

  DATA_SIZE=$(numfmt --from=iec "$SPACE")

  if (( DATA_SIZE < 104857600 )); then
    error "Please increase the ${DISK_DESC^^}_SIZE variable to at least 100 MB." && exit 73
  fi

  FS=$(stat -f -c %T "$DIR")
  checkFS "$FS" "$DISK_FILE" "$DISK_DESC" || exit $?

  if ! supportsDirect "$FS"; then
    DISK_IO="threads"
    DISK_CACHE="writeback"
  fi

  if [ ! -s "$DISK_FILE" ] ; then

    if [[ "${DISK_FMT,,}" != "raw" ]]; then
      PREV_FMT="raw"
    else
      PREV_FMT="qcow2"
    fi

    PREV_EXT=$(fmt2ext "$PREV_FMT")

    if [ -s "$DISK_BASE.$PREV_EXT" ] ; then
      convertDisk "$DISK_BASE.$PREV_EXT" "$PREV_FMT" "$DISK_FILE" "$DISK_FMT" "$DISK_BASE" "$DISK_DESC" "$FS" || exit $?
    fi

  fi

  if [ -s "$DISK_FILE" ]; then

    CUR_SIZE=$(getSize "$DISK_FILE")

    if (( DATA_SIZE > CUR_SIZE )); then

      resizeDisk "$DISK_FILE" "$SPACE" "$DISK_DESC" "$DISK_FMT" "$FS" || exit $?

    else

      if (( DATA_SIZE < CUR_SIZE )); then

        if [[ "${DISK_SPACE,,}" != "max" && "${DISK_SPACE,,}" != "half" ]]; then
          info "You decreased the ${DISK_DESC^^}_SIZE variable to ${DISK_SPACE/G/ GB} but shrinking disks is not supported, will be ignored..."
        fi

      fi
    fi

  else

    createDisk "$DISK_FILE" "$SPACE" "$DISK_DESC" "$DISK_FMT" "$FS" || exit $?

  fi

  if [ -f "$DISK_FILE" ] && [[ "$ALLOCATE" == [Nn]* ]]; then

    CUR_SIZE=$(getSize "$DISK_FILE")
    USED=$(du -sB 1 "$DISK_FILE" | cut -f1)
    FREE=$(df --output=avail -B 1 "$DIR" | tail -n 1)
    LEFT=$(( CUR_SIZE - USED - FREE ))

    if (( LEFT > 0 )); then

      GB=$(formatBytes "$FREE")
      LEFT=$(formatBytes "$LEFT")
      CUR_SIZE=$(formatBytes "$CUR_SIZE")
      msg="the virtual size of the ${DISK_DESC,,} is $CUR_SIZE"

      if [[ "$USED" == "0" ]]; then
        msg+=","
      else
        USED=$(formatBytes "$USED")
        msg+=" (of which $USED is used),"
      fi

      warn "$msg but there is only $GB of free space left in $DIR, make at least $LEFT more room available!"

    fi

  fi

  DISK_OPTS+=$(createDevice "$DISK_FILE" "$DISK_TYPE" "$DISK_INDEX" "$DISK_ADDRESS" "$DISK_FMT" "$DISK_IO" "$DISK_CACHE" "" "")

  return 0
}

addDevice () {

  local DISK_DEV="$1"
  local DISK_TYPE="$2"
  local DISK_INDEX="$3"
  local DISK_ADDRESS="$4"

  [ -z "$DISK_DEV" ] && return 0
  [ ! -b "$DISK_DEV" ] && error "Device $DISK_DEV cannot be found! Please add it to the 'devices' section of your compose file." && exit 55

  local sectors=""
  local result logical physical
  result=$(fdisk -l "$DISK_DEV" | grep -m 1 -o "(logical/physical): .*" | cut -c 21-)
  logical="${result%% *}"
  physical=$(echo "$result" | grep -m 1 -o "/ .*" | cut -c 3-)
  physical="${physical%% *}"

 if [ -n "$physical" ]; then
    if [[ "$physical" != "512" ]]; then
      sectors=",logical_block_size=$logical,physical_block_size=$physical"
    fi
  else
    warn "Failed to determine the sector size for $DISK_DEV"
  fi

  DISK_OPTS+=$(createDevice "$DISK_DEV" "$DISK_TYPE" "$DISK_INDEX" "$DISK_ADDRESS" "raw" "$DISK_IO" "$DISK_CACHE" "" "$sectors")

  return 0
}

msg="Initializing disks..."
html "$msg"
[[ "$DEBUG" == [Yy1]* ]] && echo "$msg"

[ -z "${DISK_OPTS:-}" ] && DISK_OPTS=""
[ -z "${DISK_TYPE:-}" ] && DISK_TYPE="scsi"
[ -z "${DISK_NAME:-}" ] && DISK_NAME="data"

case "${DISK_TYPE,,}" in
  "ide" | "sata" | "nvme" | "usb" | "scsi" | "blk" | "auto" | "none" ) ;;
  * ) error "Invalid DISK_TYPE specified, value \"$DISK_TYPE\" is not recognized!" && exit 80 ;;
esac

if [[ "${PLATFORM,,}" != "arm64" ]]; then
  FALLBACK="ide"
else
  FALLBACK="usb"
fi

[[ "${BOOT_MODE:-}" == "windows_legacy" ]] && FALLBACK="auto"

if [ -z "${MEDIA_TYPE:-}" ]; then
  if [[ "${BOOT_MODE:-}" != "windows"* ]]; then
    if [[ "${DISK_TYPE,,}" == "blk" ]]; then
      MEDIA_TYPE="$FALLBACK"
    else
      MEDIA_TYPE="$DISK_TYPE"
    fi
  else
    MEDIA_TYPE="$FALLBACK"
  fi
fi

case "${MEDIA_TYPE,,}" in
  "ide" | "sata" | "nvme" | "usb" | "scsi" | "blk" | "auto" | "none" ) ;;
  * ) error "Invalid MEDIA_TYPE specified, value \"$MEDIA_TYPE\" is not recognized!" && exit 80 ;;
esac

if [ -f "$BOOT" ] && [ -s "$BOOT" ]; then
  case "${BOOT,,}" in
    *".iso" )
        if [[ "${BOOT_MODE:-}" == "windows"* ]]; then
          hybrid="0000"
        else
          hybrid=$(head -c 512 "$BOOT" | tail -c 2 | xxd -p)
        fi
        if [[ "$hybrid" != "0000" ]]; then
          DISK_OPTS+=$(addMedia "$BOOT" "usb" "$BOOT_INDEX" "0x5")
        else
          DISK_OPTS+=$(addMedia "$BOOT" "$MEDIA_TYPE" "$BOOT_INDEX" "0x5")
        fi ;;
    *".img" | *".raw" )
        DISK_OPTS+=$(createDevice "$BOOT" "$DISK_TYPE" "$BOOT_INDEX" "0x5" "raw" "$DISK_IO" "$DISK_CACHE" "" "") ;;
    *".qcow2" )
        DISK_OPTS+=$(createDevice "$BOOT" "$DISK_TYPE" "$BOOT_INDEX" "0x5" "qcow2" "$DISK_IO" "$DISK_CACHE" "" "") ;;
    * )
        error "Invalid BOOT image specified, extension \".${BOOT/*./}\" is not recognized!" && exit 80 ;;
  esac
fi

DRIVERS="/drivers.iso"
[ ! -f "$DRIVERS" ] || [ ! -s "$DRIVERS" ] && DRIVERS="$STORAGE/drivers.iso"

if [ -f "$DRIVERS" ] && [ -s "$DRIVERS" ]; then
  DISK_OPTS+=$(addMedia "$DRIVERS" "$FALLBACK" "" "0x6")
fi

RESCUE="/start.iso"
[ ! -f "$RESCUE" ] || [ ! -s "$RESCUE" ] && RESCUE="$STORAGE/start.iso"

if [ -f "$RESCUE" ] && [ -s "$RESCUE" ]; then
  DISK_OPTS+=$(addMedia "$RESCUE" "$FALLBACK" "1" "0x6")
fi

DISK1_FILE="$STORAGE/${DISK_NAME}"
DISK2_FILE="/storage2/${DISK_NAME}2"
DISK3_FILE="/storage3/${DISK_NAME}3"
DISK4_FILE="/storage4/${DISK_NAME}4"
DISK5_FILE="/storage5/${DISK_NAME}5"
DISK6_FILE="/storage6/${DISK_NAME}6"

if [ -z "$DISK_FMT" ]; then
  if [ -f "$DISK1_FILE.qcow2" ]; then
    DISK_FMT="qcow2"
  else
    DISK_FMT="raw"
  fi
fi

if [ -z "$ALLOCATE" ]; then
  ALLOCATE="N"
fi

if [[ "$ALLOCATE" == [Nn]* ]]; then
  DISK_STYLE="growable"
  DISK_ALLOC="preallocation=off"
else
  DISK_STYLE="preallocated"
  DISK_ALLOC="preallocation=falloc"
fi

: "${DISK2_SIZE:=""}"
: "${DISK3_SIZE:=""}"
: "${DISK4_SIZE:=""}"
: "${DISK5_SIZE:=""}"
: "${DISK6_SIZE:=""}"

: "${DEVICE:=""}"        # Docker variables to passthrough a block device, like /dev/vdc1.
: "${DEVICE2:=""}"
: "${DEVICE3:=""}"
: "${DEVICE4:=""}"
: "${DEVICE5:=""}"
: "${DEVICE6:=""}"

[ -z "$DEVICE" ] && [ -b "/disk" ] && DEVICE="/disk"
[ -z "$DEVICE" ] && [ -b "/disk1" ] && DEVICE="/disk1"
[ -z "$DEVICE2" ] && [ -b "/disk2" ] && DEVICE2="/disk2"
[ -z "$DEVICE3" ] && [ -b "/disk3" ] && DEVICE3="/disk3"
[ -z "$DEVICE4" ] && [ -b "/disk4" ] && DEVICE4="/disk4"
[ -z "$DEVICE5" ] && [ -b "/disk5" ] && DEVICE5="/disk5"
[ -z "$DEVICE6" ] && [ -b "/disk6" ] && DEVICE6="/disk6"

[ -z "$DEVICE" ] && [ -b "/dev/disk1" ] && DEVICE="/dev/disk1"
[ -z "$DEVICE2" ] && [ -b "/dev/disk2" ] && DEVICE2="/dev/disk2"
[ -z "$DEVICE3" ] && [ -b "/dev/disk3" ] && DEVICE3="/dev/disk3"
[ -z "$DEVICE4" ] && [ -b "/dev/disk4" ] && DEVICE4="/dev/disk4"
[ -z "$DEVICE5" ] && [ -b "/dev/disk5" ] && DEVICE4="/dev/disk5"
[ -z "$DEVICE6" ] && [ -b "/dev/disk6" ] && DEVICE4="/dev/disk6"

if [ -n "$DEVICE" ]; then
  addDevice "$DEVICE" "$DISK_TYPE" "3" "0xa" || exit $?
else
  # 检查是否应该使用 overlay 磁盘
  if shouldUseOverlay; then
    # 初始化 overlay 磁盘
    if initOverlayDisk; then
      # 使用 overlay 磁盘文件
      overlay_disk="$STORAGE/data-overlay.qcow2"
      info "Using overlay disk: $overlay_disk"
      
      # 检测overlay磁盘是否真的存在
      if [ ! -f "$overlay_disk" ]; then
        error "Warning: Overlay disk file not found at: $overlay_disk"
        # 尝试使用绝对路径
        if [ ! -f "/storage/data-overlay.qcow2" ]; then
          error "CRITICAL: Overlay disk not found at both paths!"
          # 尝试重新创建overlay磁盘作为最后的手段
          info "Attempting to recreate overlay disk..."
          if [ -f "$STORAGE/data.img" ]; then
            if createOverlayDisk "$STORAGE/data.img" "/storage/data-overlay.qcow2"; then
              info "Overlay disk recreated successfully"
              overlay_disk="/storage/data-overlay.qcow2"
            else
              error "Failed to recreate overlay disk. Falling back to base disk."
              overlay_disk="$STORAGE/data.img"
            fi
          else
            error "No base disk found for recreation."
            exit 1
          fi
        else
          info "Using absolute path for overlay disk"
          overlay_disk="/storage/data-overlay.qcow2"
        fi
      fi
      
      DISK_OPTS+=$(createDevice "$overlay_disk" "$DISK_TYPE" "3" "0xa" "qcow2" "$DISK_IO" "$DISK_CACHE" "" "")
    else
      # 回退到原始逻辑
      error "Failed to initialize overlay disk, falling back to normal disk creation"
      addDisk "$DISK1_FILE" "$DISK_TYPE" "disk" "$DISK_SIZE" "3" "0xa" "$DISK_FMT" "$DISK_IO" "$DISK_CACHE" || exit $?
    fi
  else
    # 使用原始逻辑
    info "Using normal disk creation"
    addDisk "$DISK1_FILE" "$DISK_TYPE" "disk" "$DISK_SIZE" "3" "0xa" "$DISK_FMT" "$DISK_IO" "$DISK_CACHE" || exit $?
  fi
fi

if [ -n "$DEVICE2" ]; then
  addDevice "$DEVICE2" "$DISK_TYPE" "4" "0xb" || exit $?
else
  addDisk "$DISK2_FILE" "$DISK_TYPE" "disk2" "$DISK2_SIZE" "4" "0xb" "$DISK_FMT" "$DISK_IO" "$DISK_CACHE" || exit $?
fi

if [ -n "$DEVICE3" ]; then
  addDevice "$DEVICE3" "$DISK_TYPE" "5" "0xc" || exit $?
else
  addDisk "$DISK3_FILE" "$DISK_TYPE" "disk3" "$DISK3_SIZE" "5" "0xc" "$DISK_FMT" "$DISK_IO" "$DISK_CACHE" || exit $?
fi

if [ -n "$DEVICE4" ]; then
  addDevice "$DEVICE4" "$DISK_TYPE" "6" "0xd" || exit $?
else
  addDisk "$DISK4_FILE" "$DISK_TYPE" "disk4" "$DISK4_SIZE" "6" "0xd" "$DISK_FMT" "$DISK_IO" "$DISK_CACHE" || exit $?
fi

if [ -n "$DEVICE5" ]; then
  addDevice "$DEVICE5" "$DISK_TYPE" "7" "0xe" || exit $?
else
  addDisk "$DISK5_FILE" "$DISK_TYPE" "disk5" "$DISK5_SIZE" "7" "0xe" "$DISK_FMT" "$DISK_IO" "$DISK_CACHE" || exit $?
fi

if [ -n "$DEVICE6" ]; then
  addDevice "$DEVICE6" "$DISK_TYPE" "8" "0xf" || exit $?
else
  addDisk "$DISK6_FILE" "$DISK_TYPE" "disk6" "$DISK6_SIZE" "8" "0xf" "$DISK_FMT" "$DISK_IO" "$DISK_CACHE" || exit $?
fi

DISK_OPTS+=" -object iothread,id=io2"



html "Initialized disks successfully..."
return 0
