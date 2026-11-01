#!/vendor/bin/sh
# bring-up monitor: dump svc states into kmsg every 5s
while true; do
  echo "BRGUP t=$(cut -d' ' -f1 /proc/uptime) bootc=$(getprop sys.boot_completed) sf=$(getprop init.svc.surfaceflinger) adbd=$(getprop init.svc.adbd) anim=$(getprop init.svc.bootanim) zyg=$(getprop init.svc.zygote) usb=$(getprop sys.usb.state)" > /dev/kmsg
  sleep 5
done
