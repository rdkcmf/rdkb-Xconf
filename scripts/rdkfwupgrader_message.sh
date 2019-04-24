#!/bin/sh
# NOTE:: RDKB-20262 if rdkfwupgrader daemon is enabled, don't do anything in these scripts.
# this is to safeguard against future mistakes or corner cases where someone
# calls these scripts directly
XCONF_LOG_FILE=/rdklogs/logs/xconf.txt.0

BOX=`grep BOX_TYPE /etc/device.properties | cut -d "=" -f2 | tr 'A-Z' 'a-z'`
RDKFWUpgrader_PID=`pidof rdkfwupgrader`
isRDKFWUpgraderEnabled=`syscfg get RDKFirmwareUpgraderEnabled`
if [ "x$isRDKFWUpgraderEnabled" = "xtrue" ] && [ -z "$RDKFWUpgrader_PID" ] ; then
    log_line1="Deprecation Warning: RDKFirmwareUpgrader daemon is enabled, usage of new scripts will be allowed after reboot"
    log_line2="Deprecation Warning: use rdkfwupgrader_check_now.sh if you need to force an upgrade"
    echo "$log_line1"
    echo "$log_line2"
    echo "$log_line1" >> $XCONF_LOG_FILE
    echo "$log_line2" >> $XCONF_LOG_FILE
    if [ "$BOX" = "tccbr" ]; then
      DOWNLOAD_SCRIPT="/etc/cbr_firmwareDwnld.sh"
      SCRIPT_NAME="cbr_firmwareDwnld.sh"
    else
      FIRMWARE_DOWNLOAD='_firmwareDwnld.sh'
      DOWNLOAD_SCRIPT="/etc/$BOX$FIRMWARE_DOWNLOAD"
      SCRIPT_NAME="$BOX$FIRMWARE_DOWNLOAD"
    fi
    exit 0 
fi
