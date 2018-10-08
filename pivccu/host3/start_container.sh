#!/bin/bash

. /etc/default/pivccu3

modprobe -a eq3_char_loop &> /dev/null
if [ $? -ne 0 ]; then
  logger -t piVCCU3 -p user.err -s "Could not load kernel modules plat_eq3ccu2 and eq3_char_loop." 1>&2
  exit 1
fi

. /var/lib/piVCCU3/detect_hardware.inc

if [ -z "$HMRF_HARDWARE" ]; then
  logger -t piVCCU3 -p user.warn -s "HMRF hardware was not detected" 1>&2
fi

if [ -z "$HMIP_HARDWARE" ]; then
  logger -t piVCCU3 -p user.warn -s "HMIP hardware was not detected" 1>&2
fi

mkdir -p /var/lib/piVCCU3/lxc

if [ -z "$BRIDGE" ]; then
  logger -t piVCCU3 -p user.warning -s "No network bridge could be detected." 1>&2
fi

rm -rf /tmp/pivccu-media
mkdir -p /tmp/pivccu-media

rm -rf /tmp/pivccu-var
mkdir -p /tmp/pivccu-var/pivccu

CONFIG_FILE=/var/lib/piVCCU3/lxc/config
cat /etc/piVCCU3/lxc.config > $CONFIG_FILE

sed -i $CONFIG_FILE -e "s/<mac_auto>/$MAC/"
sed -i $CONFIG_FILE -e "s/<bridge_auto>/$BRIDGE/"
sed -i $CONFIG_FILE -e "s/<eq3loop_major>/$EQ3LOOP_MAJOR/"
sed -i $CONFIG_FILE -e "s/<uart_major>/$UART_MAJOR/"
sed -i $CONFIG_FILE -e "s/<hmip_major>/$HMIP_MAJOR/"
sed -i $CONFIG_FILE -e "s/<hmip_minor>/$HMIP_MINOR/"

cat > /tmp/pivccu-var/pivccu/conf << EOF
HMRF_HARDWARE="$HMRF_HARDWARE"
HMIP_HARDWARE="$HMIP_HARDWARE"
SGTIN="$SGTIN"
FW_VERSION="$FW_VERSION"
EQ3LOOP_MAJOR="$EQ3LOOP_MAJOR"
UART_MAJOR="$UART_MAJOR"
HMIP_MAJOR="$HMIP_MAJOR"
HMIP_MINOR="$HMIP_MINOR"
BOARD_SERIAL="$BOARD_SERIAL"
RADIO_MAC="$RADIO_MAC"
EOF

OIFS=$IFS
IFS=,
declare -a devices=($PIVCCU_USB_DEVICES)
IFS=$OIFS

USBDISKINDEX=1

for dev in ${devices[@]}; do
  IFS=";" read vendor_id model_id serial_short usb_interface_num part_entry_uuid  <<< "$dev"

  FOUND=0
  for sysdevpath in $(find /sys/bus/usb/devices/usb*/ -name dev); do
    syspath="${sysdevpath%/dev}"

    declare -A UDEV_PROPERTIES=()
    while IFS='=' read -r a b; do UDEV_PROPERTIES["$a"]="$b"; done < <(udevadm info -q property -p $syspath)

    [[ "${UDEV_PROPERTIES[ID_VENDOR_ID]}" != "$vendor_id" ]] && continue
    [[ "${UDEV_PROPERTIES[ID_MODEL_ID]}" != "$model_id" ]] && continue
    [[ "${UDEV_PROPERTIES[ID_SERIAL_SHORT]}" != "$serial_short" ]] && continue
    [[ "${UDEV_PROPERTIES[ID_USB_INTERFACE_NUM]}" != "$usb_interface_num" ]] && continue
    [[ "${UDEV_PROPERTIES[ID_PART_ENTRY_UUID]}" != "$part_entry_uuid" ]] && continue

    FOUND=1

    if [ "${UDEV_PROPERTIES[DEVTYPE]}" == "partition" ]; then
      DEVTYPE="b"
      echo "mount -t ${UDEV_PROPERTIES[ID_FS_TYPE]} -o noexec,nodev,noatime,nodiratime ${UDEV_PROPERTIES[DEVNAME]} /media/usb$USBDISKINDEX" >> /tmp/pivccu-var/pivccu/create-mounts
      mkdir -p /tmp/pivccu-media/usb$USBDISKINDEX
      if [ ! -e /tmp/pivccu-media/usb0 ]; then
        ln -s /media/usb$USBDISKINDEX /tmp/pivccu-media/usb0
      fi
      mkdir -p /tmp/pivccu-var/status
      touch /tmp/pivccu-var/status/hasUSB
      touch /tmp/pivccu-var/status/hasSD
      let "USBDISKINDEX++"
    else
      DEVTYPE="c"
    fi

    echo "lxc.cgroup.devices.allow = $DEVTYPE ${UDEV_PROPERTIES[MAJOR]}:${UDEV_PROPERTIES[MINOR]} rwm" >> $CONFIG_FILE

    echo "rm -f ${UDEV_PROPERTIES[DEVNAME]}" >> /tmp/pivccu-var/pivccu/create-devs
    echo "mknod -m 666 ${UDEV_PROPERTIES[DEVNAME]} $DEVTYPE ${UDEV_PROPERTIES[MAJOR]} ${UDEV_PROPERTIES[MINOR]}" >> /tmp/pivccu-var/pivccu/create-devs
  done

  (($FOUND)) && continue
  logger -t piVCCU3 -p user.warning -s "Could not find configured USB device $vendor_id:$model_id ($serial_short)." 1>&2
done

sysctl -w kernel.sched_rt_runtime_us=-1

if [ -x /etc/piVCCU3/pre-start.sh ]; then
  /etc/piVCCU3/pre-start.sh
fi

/usr/bin/lxc-start --lxcpath /var/lib/piVCCU3 --name lxc --pidfile /var/run/pivccu3.pid --daemon

if [ -x /etc/piVCCU3/post-start.sh ]; then
  /etc/piVCCU3/post-start.sh
fi

