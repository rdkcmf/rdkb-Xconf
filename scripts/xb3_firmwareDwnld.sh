#!/bin/sh
##########################################################################
# If not stated otherwise in this file or this component's Licenses.txt
# file the following copyright and licenses apply:
#
# Copyright 2017 RDK Management
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
##########################################################################

source /etc/utopia/service.d/log_capture_path.sh
source /fss/gw/etc/utopia/service.d/log_env_var.sh
source /lib/rdk/getpartnerid.sh
source /lib/rdk/getaccountid.sh
source /lib/rdk/t2Shared_api.sh
source /etc/waninfo.sh

if [ -f /etc/device.properties ]
then
    source /etc/device.properties
fi

if [ -f /etc/bundleUtils.sh ]
then
    source /etc/bundleUtils.sh
fi

XCONF_LOG_FILE_NAME=xconf.txt.0
XCONF_LOG_FILE_PATHNAME=${LOG_PATH}/${XCONF_LOG_FILE_NAME}
XCONF_LOG_FILE=${XCONF_LOG_FILE_PATHNAME}

CURL_PATH=/fss/gw/usr/bin
interface=$(getWanInterfaceName)
wan_interface=$(getWanMacInterfaceName)
BIN_PATH=/fss/gw/usr/bin
REBOOT_WAIT="/tmp/.waitingreboot"
DOWNLOAD_INPROGRESS="/tmp/.downloadingfw"
deferReboot="/tmp/.deferringreboot"
NO_DOWNLOAD="/tmp/.downloadBreak"
ABORT_REBOOT="/tmp/AbortReboot"
Downloaded="/tmp/Downloadedimage"
abortReboot_count=0

HTTP_CODE=/tmp/fwdl_http_code.txt
FWDL_JSON=/tmp/response.txt

SIGN_FILE="/tmp/.signedRequest_$$_`date +'%s'`"

CODEBIG_BLOCK_TIME=1800
CODEBIG_BLOCK_FILENAME="/tmp/.lastcodebigfail_cdl"
FORCE_DIRECT_ONCE="/tmp/.forcedirectonce_cdl"

CONN_TRIES=3

#to support ocsp
EnableOCSPStapling="/tmp/.EnableOCSPStapling"
EnableOCSP="/tmp/.EnableOCSPCA"

if [ -f $EnableOCSPStapling ] || [ -f $EnableOCSP ]; then
    CERT_STATUS="--cert-status"
fi

CONN_RETRIES=3
curr_conn_type=""
conn_str="Direct"
CodebigAvailable=0
UseCodebig=0

CURL_SSR_PARAM=""
FW_START="/nvram/.FirmwareUpgradeStartTime"
FW_END="/nvram/.FirmwareUpgradeEndTime"

CRONTAB_DIR="/var/spool/cron/crontabs/"
CRON_FILE_BK="/tmp/cron_tab$$.txt"
LAST_HTTP_RESPONSE="/tmp/XconfSavedOutput"

#GLOBAL DECLARATIONS
image_upg_avl=0
isWanLinkHealEnabled=`syscfg get wanlinkheal`

DAC15_DOMAIN="dac15cdlserver.ae.ccp.xcal.tv"

# NOTE:: RDKB-20262 if rdkfwupgrader daemon is enabled, don't do anything in these scripts.
    /etc/rdkfwupgrader_message.sh
    
    if [ $? -ne 0 ] ;then
        exit 1
    fi



#
# release numbering system rules
#

# 5 part release numbering scheme where the five parts consisted of 
#+ "Major Rev"."Minor Rev"."Internal Rev". "Patch Level"."SPIN".

# 1.Major  Rev and Minor Rev will follow the matching RDKB version.
# 2.Any field which formerly contained  a zero (except for "Minor Rev") will be suppressed in the build number as well as the preceding "."
# 3.The "Spin" field will be  preceded by  "s"  for spin,  rather than a ".'  ie s4
# 4.The Spin field is always in the range of 1-x; Since it is  never 0, this field is always present.
# 5.The "Patch Level" field will be preceded by  "p" (lower case)  for patch rather than a "." . ie p2
# 6.The patch level field is in the range of 0-x.  If the patch level value is zero, the entire field will be suppressed including the leading "p". 
# 7."Internal Rev" can be in the range of 0-x, When the value of Internal Rev is 0, it will be suppressed, including the preceding "."
# 8.Initial State: We will be reverting the Internal Rev to Zero. This will allow us to suppress the field initially
# 9. The "Patch level" filed if present will always preceed "Spin" field.

# example build release numbers
# 1.22s55555                    spin_on_minor           3
# 1.22p4444s55555               spin_on_patch           1
# 1.22.333s55555                spin_on_internal        2
# 1.22.333p4444s55555           spin_on_patch           3
# 

# param1 : cur_rel_num param2 : upg_rel_num
# assumption : 
#       cur and upg firmware version are validated against release numbering system rules
#       no assumption is made about the length of the fields
# spin_on : 1 spin_on_patch 2 spin_on_internal 3 spin_on_minor


# Get currrent firmware in th eunit
getCurrentFw()
{
 currentfw=""
 # Check the location of version.txt file
 if [ -f "/fss/gw/version.txt" ]
 then
    currentfw=`grep image /fss/gw/version.txt | cut -f2 -d:`
 elif [ -f "/version.txt" ]
 then
    if [ "$currentfw" = "" ]
	then
        currentfw=`grep image /version.txt | cut -f2 -d:`
	fi
 fi
 echo $currentfw
}

getRequestType()
{
     request_type=2
     if [ "$1" == "ci.xconfds.ccp.xcal.tv" ]; then
            request_type=4
     fi
     return $request_type
}

checkFirmwareUpgCriteria()
{
    image_upg_avl=0;

    # Retrieve current firmware version
    currentVersion=`getCurrentFw`
    current_FW_Version=$currentVersion
    update_FW_Version=$firmwareVersion
    #Comcast signed firmware images are represented in lower case and vendor signed images are represented in upper case.
    #In order to avoid confusion in string comparison, converting both currentVersion and firmwareVersion to lower case.
    currentVersion=`echo $currentVersion | tr '[A-Z]' '[a-z]'`
    firmwareVersion=`echo $firmwareVersion | tr '[A-Z]' '[a-z]'`


    echo_t "XCONF SCRIPT : CurrentVersion : $currentVersion"
    echo_t "XCONF SCRIPT : UpgradeVersion : $firmwareVersion"

    echo_t "XCONF SCRIPT : CurrentVersion : $currentVersion" >> $XCONF_LOG_FILE
    echo_t "XCONF SCRIPT : UpgradeVersion : $firmwareVersion" >> $XCONF_LOG_FILE

    if [ "$currentVersion" != "" ] && [ "$firmwareVersion" != "" ];then
		if [ "$currentVersion" == "$firmwareVersion" ]; then
			echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are same. No upgrade/downgrade required"
			echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are same. No upgrade/downgrade required">> $XCONF_LOG_FILE
			image_upg_avl=0
            exit
		else
			echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are different. Processing Upgrade/Downgrade"
			echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are different. Processing Upgrade/Downgrade">> $XCONF_LOG_FILE
			image_upg_avl=1
		fi
	else
		echo_t "XCONF SCRIPT : Current image ("$currentVersion") Or Requested image ("$firmwareVersion") returned NULL. No Upgrade/Downgrade"
		echo_t "XCONF SCRIPT : Current image ("$currentVersion") Or Requested image ("$firmwareVersion") returned NULL. No Upgrade/Downgrade">> $XCONF_LOG_FILE
		image_upg_avl=0
        exit
	fi
}

IsCodebigBlocked()
{
    ret=0
    if [ -f $CODEBIG_BLOCK_FILENAME ]; then
        modtime=$(($(date +%s) - $(date +%s -r $CODEBIG_BLOCK_FILENAME)))
        if [ "$modtime" -le "$CODEBIG_BLOCK_TIME" ]; then
            echo "XCONF SCRIPT: Last Codebig failed blocking is still valid, preventing Codebig" >>  $DCM_LOG_FILE
            ret=1
        else
            echo "XCONF SCRIPT: Last Codebig failed blocking has expired, removing $CODEBIG_BLOCK_FILENAME, allowing Codebig" >> $DCM_LOG_FILE
            rm -f $CODEBIG_BLOCK_FILENAME
            ret=0
        fi
    fi
    return $ret
}

# Get the configuration of codebig settings
get_Codebigconfig()
{
   # If configparamgen not available, then only direct connection available and no fallback mechanism
   if [ -f $CONFIGPARAMGEN ]; then
      CodebigAvailable=1
   fi
   if [ "$CodebigAvailable" -eq "1" ]; then 
       CodeBigEnable=`dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Feature.CodeBigFirst.Enable | grep value | cut -f3 -d : | cut -f2 -d " "`
   fi
   if [ -f $FORCE_DIRECT_ONCE ]; then
      rm -f $FORCE_DIRECT_ONCE
      echo_t "XCONF SCRIPT : Last Codebig attempt failed, forcing direct once" >> $XCONF_LOG_FILE
   elif [ "$CodebigAvailable" -eq "1" ] && [ "x$CodeBigEnable" == "xtrue" ] ; then
      UseCodebig=1
      conn_str="Codebig" 
   fi

   echo_t "XCONF SCRIPT : Using $conn_str connection as the Primary"
   echo_t "XCONF SCRIPT : Using $conn_str connection as the Primary" >> $XCONF_LOG_FILE
}

# Get and set the codebig signed info
do_Codebig_signing()
{
     if [ "$1" = "Xconf" ]; then
            domain_name=`echo $xconf_url | cut -d / -f3`
            getRequestType $domain_name
            request_type=$?
            SIGN_CMD="configparamgen $request_type \"$JSONSTR\""
            eval $SIGN_CMD > $SIGN_FILE
            CB_SIGNED_REQUEST=`cat $SIGN_FILE`
            rm -f $SIGN_FILE
      else
            request_type=1
            domainName=`echo $imageHTTPURL | awk -F/ '{print $3}'`
            if [ "$domainName" == "$DAC15_DOMAIN" ]; then
                request_type=14
            fi
            SIGN_CMD="configparamgen $request_type \"$imageHTTPURL\""
            echo $SIGN_CMD >>$XCONF_LOG_FILE
            echo -e "\n"
            eval $SIGN_CMD > $SIGN_FILE
            cbSignedimageHTTPURL=`cat $SIGN_FILE`
            rm -f $SIGN_FILE
#            echo $cbSignedimageHTTPURL >>$XCONF_LOG_FILE
            cbSignedimageHTTPURL=`echo $cbSignedimageHTTPURL | sed 's|stb_cdl%2F|stb_cdl/|g'`
            serverUrl=`echo $cbSignedimageHTTPURL | sed -e "s|[?&]oauth_consumer_key.*||g"`
            authorizationHeader=`echo $cbSignedimageHTTPURL | sed -e "s|&|\", |g" -e "s|=|=\"|g" -e "s|.*oauth_consumer_key|oauth_consumer_key|g"`
            authorizationHeader="Authorization: OAuth realm=\"\", $authorizationHeader\""
            CURL_SSR_PARAM="-H '$authorizationHeader' -fgL '$serverUrl'"
      fi
}

# Direct connection Download function
useDirectRequest()
{
            curr_conn_type="direct"
            echo_t "Trying Direct Communication"
            echo_t "Trying Direct Communication" >> $XCONF_LOG_FILE
            CURL_CMD="$CURL_PATH/curl --interface $interface $addr_type -w '%{http_code}\n' --tlsv1.2 -d \"$JSONSTR\" -o \"$FWDL_JSON\" \"$xconf_url\" $CERT_STATUS --connect-timeout 30 -m 30"
            echo_t "CURL_CMD:$CURL_CMD"
            echo_t "CURL_CMD:$CURL_CMD" >> $XCONF_LOG_FILE
            HTTP_CODE=`result= eval $CURL_CMD`
            ret=$?
            HTTP_RESPONSE_CODE=$(echo "$HTTP_CODE" | awk -F\" '{print $1}' )
            echo_t "Direct Communication - ret:$ret, http_code:$HTTP_RESPONSE_CODE" | tee -a $XCONF_LOG_FILE ${LOG_PATH}/TlsVerify.txt
            # log security failure
            case $ret in
              35|51|53|54|58|59|60|64|66|77|80|82|83|90|91)
                echo_t "Direct Communication Failure - ret:$ret, http_code:$HTTP_RESPONSE_CODE" >> $XCONF_LOG_FILE
                ;;
            esac
            [ "x$HTTP_RESPONSE_CODE" != "x" ] || HTTP_RESPONSE_CODE=0
}

# Codebig connection Download function
useCodebigRequest()
{
            curr_conn_type="codebig"
            # Do not try Codebig if CodebigAvailable != 1 (configparamgen not there)
            if [ "$CodebigAvailable" -eq "0" ] ; then
                  echo_t "XCONF SCRIPT: Only direct connection Available" >> $XCONF_LOG_FILE
                  return 1
            fi

            IsCodebigBlocked
            if [ "$?" -eq "1" ]; then
                return 1
            fi
            do_Codebig_signing "Xconf"
            CURL_CMD="$CURL_PATH/curl --interface $interface $addr_type -w '%{http_code}\n' --tlsv1.2 -o \"$FWDL_JSON\" \"$CB_SIGNED_REQUEST\" $CERT_STATUS --connect-timeout 30 -m 30"
            echo_t "Trying Codebig Communication at `echo "$CURL_CMD" | sed -ne 's#.*\(https:.*\)?.*#\1#p'`"
            echo_t "Trying Codebig Communication at `echo "$CURL_CMD" | sed -ne 's#.*\(https:.*\)?.*#\1#p'`" >> $XCONF_LOG_FILE
            echo_t "CURL_CMD: `echo "$CURL_CMD" | sed -ne 's#oauth_consumer_key=.*oauth_signature.* --#<hidden> --#p'`" 
            echo_t "CURL_CMD: `echo "$CURL_CMD" | sed -ne 's#oauth_consumer_key=.*oauth_signature.* --#<hidden> --#p'`"  >> $XCONF_LOG_FILE
            HTTP_CODE=`result= eval $CURL_CMD`
            ret=$?
            HTTP_RESPONSE_CODE=$(echo "$HTTP_CODE" | awk -F\" '{print $1}' )
            echo_t "Codebig Communication - ret:$ret, http_code:$HTTP_RESPONSE_CODE" | tee -a $XCONF_LOG_FILE ${LOG_PATH}/TlsVerify.txt
            # log security failure
            case $ret in
              35|51|53|54|58|59|60|64|66|77|80|82|83|90|91)
                echo_t "Codebig Communication Failure - ret:$ret, http_code:$HTTP_RESPONSE_CODE" >> $XCONF_LOG_FILE
                ;;
            esac
}


# Check if a new image is available on the XCONF server
getFirmwareUpgDetail()
{
    # The retry count and flag are used to resend a 
    # query to the XCONF server if issues with the 
    # respose or the URL received
    xconf_retry_count=0
    retry_flag=1
    isIPv6=`ifconfig $interface | grep inet6 | grep -i 'Global'`

    # Set the XCONF server url read from /tmp/Xconf 
    # Determine the env from $type

    #s16 : env=`cat /tmp/Xconf | cut -d "=" -f1`
    env=$type
    
    # If an /tmp/Xconf file was not created, use the default values
    if [ ! -f /tmp/Xconf ]; then
        echo_t "XCONF SCRIPT : ERROR : /tmp/Xconf file not found! Using defaults"
        echo_t "XCONF SCRIPT : ERROR : /tmp/Xconf file not found! Using defaults" >> $XCONF_LOG_FILE
        env="PROD"
        xconf_url="https://xconf.xcal.tv/xconf/swu/stb/"
    else
        xconf_url=`cut -d "=" -f2 /tmp/Xconf`
    fi

    # if xconf_url uses http, then log it
    case $(echo "$xconf_url" | cut -d ":" -f1 | tr '[:upper:]' '[:lower:]') in
        "https")
            #echo_t "XCONF SCRIPT : firmware download config using HTTPS to $xconf_url" >> $XCONF_LOG_FILE
            ;;
        "http")
            echo_t "XCONF SCRIPT : firmware download config using HTTP to $xconf_url" >> $XCONF_LOG_FILE
            ;;
        *)
            echo_t "XCONF SCRIPT : ERROR : firmware download config using invalid URL to '$xconf_url'" >> $XCONF_LOG_FILE
            ;;
    esac

    echo_t "XCONF SCRIPT : env is $env"
    echo_t "XCONF SCRIPT : xconf url  is $xconf_url"

    # If interface doesnt have ipv6 address then we will force the curl to go with ipv4.
    # Otherwise we will not specify the ip address family in curl options
    if [ "$isIPv6" != "" ]; then
        addr_type=""
    else
        addr_type="-4"
    fi
    get_Codebigconfig

    # Check with the XCONF server if an update is available 
    while [ $xconf_retry_count -lt $CONN_TRIES ] && [ $retry_flag -eq 1 ]
    do

        echo_t "**RETRY is $((xconf_retry_count + 1)) and RETRY_FLAG is $retry_flag**" >> $XCONF_LOG_FILE
        
        # White list the Xconf server url
        #echo "XCONF SCRIPT : Whitelisting Xconf Server url : $xconf_url"
        #echo "XCONF SCRIPT : Whitelisting Xconf Server url : $xconf_url" >> $XCONF_LOG_FILE
        #/etc/whitelist.sh "$xconf_url"
        
        # Perform cleanup by deleting any previous responses
        rm -f $FWDL_JSON /tmp/XconfOutput.txt
        firmwareDownloadProtocol=""
        firmwareFilename=""
        firmwareLocation=""
        firmwareVersion=""
        rebootImmediately=""
        ipv6FirmwareLocation=""
        upgradeDelay=""
        delayDownload=""
        factoryResetImmediately=""
       
        currentVersion=`getCurrentFw`
		
        MAC=`ifconfig  | grep $wan_interface |  grep -v $wan_interface:0 | tr -s ' ' | cut -d ' ' -f5`
        date=`date`
        modelName=`dmcli eRT getv Device.DeviceInfo.ModelName | grep value | cut -d ":" -f 3 | tr -d ' ' `

		if [ "$modelName" == "" ]; then
			echo_t "XCONF SCRIPT : Device model returned NULL from DeviceInfo.ModelName . Reading it from /etc/device.properties " >> $XCONF_LOG_FILE
			modelName=$MODEL_NUM
		fi

        echo_t "XCONF SCRIPT : CURRENT VERSION : $currentVersion" 
        echo_t "XCONF SCRIPT : CURRENT MAC  : $MAC" 
        echo_t "XCONF SCRIPT : CURRENT DATE : $date"  
	echo_t "XCONF SCRIPT : MODEL : $modelName"

        # Query the  XCONF Server, using TLS 1.2
        echo_t "Attempting TLS1.2 connection to $xconf_url " >> $XCONF_LOG_FILE
        partnerId=$(getPartnerId)
        accountId=$(getAccountId)
        unitActivationStatus=`syscfg get unit_activated`

        if [ -z "$unitActivationStatus" ] || [ $unitActivationStatus -eq 0 ]; then
            activationInProgress="true"
        else
            activationInProgress="false"
        fi

		instBundles=$(getInstalledBundleList)

        JSONSTR='eStbMac='${MAC}'&firmwareVersion='${currentVersion}'&env='${env}'&model='${modelName}'&partnerId='${partnerId}'&activationInProgress='${activationInProgress}'&accountId='${accountId}'&localtime='${date}'&dlCertBundle='${instBundles}'&timezone=EST05&capabilities=rebootDecoupled&capabilities=RCDL&capabilities=supportsFullHttpUrl'
        if [ "$UseCodebig" = "1" ]; then
           useCodebigRequest
        else
           useDirectRequest
        fi
        [ "x$HTTP_RESPONSE_CODE" != "x" ] || HTTP_RESPONSE_CODE=0
        echo_t "XCONF SCRIPT : HTTP RESPONSE CODE is $HTTP_RESPONSE_CODE"
        echo_t "XCONF SCRIPT : HTTP RESPONSE CODE is $HTTP_RESPONSE_CODE" >> $XCONF_LOG_FILE

        if [ $HTTP_RESPONSE_CODE -eq 200 ];then
            # Print the response
            cat $FWDL_JSON
            echo
            cat $FWDL_JSON >> $XCONF_LOG_FILE
            echo >> $XCONF_LOG_FILE

            retry_flag=0
			
	    OUTPUT="/tmp/XconfOutput.txt" 
            cat $FWDL_JSON | tr -d '\n' | sed 's/[{}]//g' | awk  '{n=split($0,a,","); for (i=1; i<=n; i++) print a[i]}' | sed 's/\"\:\"/\|/g' | sed -r 's/\"\:(true)($)/\|true/gI' | sed -r 's/\"\:(false)($)/\|false/gI' | sed -r 's/\"\:(null)($)/\|\1/gI' | sed -r 's/\"\:(-?[0-9]+)($)/\|\1/g' | sed 's/[\,]/ /g' | sed 's/\"//g' > $OUTPUT
            
	    firmwareDownloadProtocol=`grep firmwareDownloadProtocol $OUTPUT  | cut -d \| -f2`
            echo_t "XCONF SCRIPT : firmwareDownloadProtocol [$firmwareDownloadProtocol]"
            echo_t "XCONF SCRIPT : firmwareDownloadProtocol [$firmwareDownloadProtocol]" >> $XCONF_LOG_FILE

            if [ "$firmwareDownloadProtocol" == "http" ];then
                echo_t "XCONF SCRIPT : Download image from HTTP server" >> $XCONF_LOG_FILE
                firmwareLocation=`grep firmwareLocation $OUTPUT | cut -d \| -f2 | tr -d ' '`
            else
                echo_t "XCONF SCRIPT : Download from $firmwareDownloadProtocol server not supported, check XCONF server configurations"
                echo_t "XCONF SCRIPT : Download from $firmwareDownloadProtocol server not supported, check XCONF server configurations" >> $XCONF_LOG_FILE

                retry_flag=1
                image_upg_avl=0

                if [ $xconf_retry_count -lt $((CONN_TRIES - 1)) ]; then
                    if [ "$curr_conn_type" = "direct" ]; then
                        sleep_time=120
                    elif [ "$xconf_retry_count" -eq "0" ]; then
                        sleep_time=10
                    else
                        sleep_time=30
                    fi
                   echo_t "XCONF SCRIPT : Retrying query in $sleep_time seconds" >> $XCONF_LOG_FILE
                       sleep $sleep_time
                fi
                #Increment the retry count
                xconf_retry_count=$((xconf_retry_count+1))
                continue
            fi

            firmwareFilename=`grep firmwareFilename $OUTPUT | cut -d \| -f2`
    	    firmwareVersion=`grep firmwareVersion $OUTPUT | cut -d \| -f2`
	    ipv6FirmwareLocation=`grep ipv6FirmwareLocation  $OUTPUT | cut -d \| -f2 | tr -d ' '`
	    upgradeDelay=`grep upgradeDelay $OUTPUT | cut -d \| -f2`
            delayDownload=`grep delayDownload $OUTPUT | cut -d \| -f2`
            rebootImmediately=`grep rebootImmediately $OUTPUT | cut -d \| -f2`    
            factoryResetImmediately=`grep factoryResetImmediately $OUTPUT | cut -d \| -f2`
            dlCertBundle=$($JSONQUERY -f $FWDL_JSON -p dlCertBundle)
                                    
            echo_t "XCONF SCRIPT : Protocol :"$firmwareDownloadProtocol
            echo_t "XCONF SCRIPT : Filename :"$firmwareFilename
            echo_t "XCONF SCRIPT : Location :"$firmwareLocation
            echo_t "XCONF SCRIPT : Version  :"$firmwareVersion
            echo_t "XCONF SCRIPT : Reboot   :"$rebootImmediately
            echo_t "XCONF SCRIPT : Delay Time :"$delayDownload
            echo_t "XCONF SCRIPT : factoryResetImmediately :"$factoryResetImmediately
            echo_t "XCONF SCRIPT : dlCertBundle :"$dlCertBundle
            
            dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_FirmwareDownloadURL string "$firmwareLocation"
            #RDKB-35095 AC#3
            if [ "$firmwareFilename" = "" ];then
                dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_FirmwareToDownload string "$currentVersion"
            else
                dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_FirmwareToDownload string "$firmwareFilename"
            fi

            if [ -n "$delayDownload" ]; then
                echo_t "XCONF SCRIPT : Device configured with download delay of $delayDownload minutes"
                echo_t "XCONF SCRIPT : Device configured with download delay of $delayDownload minutes" >> $XCONF_LOG_FILE
            fi

            if [ -z "$delayDownload" ] || [ "$rebootImmediately" = "true" ] || [ "$factoryResetImmediately" = "true" ] || [ $delayDownload -lt 0 ];then
                delayDownload=0
                echo_t "XCONF SCRIPT : Resetting the download delay to 0 minutes" >> $XCONF_LOG_FILE
            fi

            if [ "X"$firmwareLocation = "X" ];then
                echo_t "XCONF SCRIPT : No URL received in $FWDL_JSON"
                echo_t "XCONF SCRIPT : No URL received in $FWDL_JSON" >> $XCONF_LOG_FILE
                retry_flag=1
                image_upg_avl=0

                if [ $xconf_retry_count -lt $((CONN_TRIES - 1)) ]; then
                    if [ "$xconf_retry_count" -eq "0" ]; then
                        sleep_time=10
                    else
                        sleep_time=30
                    fi
                    echo_t "XCONF SCRIPT : Retrying query in $sleep_time seconds" >> $XCONF_LOG_FILE
                    sleep $sleep_time
                fi
                #Increment the retry count
                xconf_retry_count=$((xconf_retry_count+1))
            else
                # Will only entry here is last connection was success with 200 & http. So use the last succesful conn type.
                if [ "$curr_conn_type" != "direct" ]; then 
                    echo_t "XCONF SCRIPT : SSR download is set to : CODEBIG" 
                    echo_t "XCONF SCRIPT : SSR download is set to : CODEBIG" >> $XCONF_LOG_FILE
                    serverUrl=""
                    authorizationHeader=""
                    imageHTTPURL="$firmwareLocation/$firmwareFilename"
                    domainName=`echo $imageHTTPURL | awk -F/ '{print $3}'`
                    imageHTTPURL=`echo $imageHTTPURL | sed -e "s|.*$domainName||g"`
                    do_Codebig_signing "SSR" 
                    # firmwareLocation=`echo "$serverUrl" | sed -ne 's/\/'"$firmwareFilename.*"'//p'`
                    echo_t "XCONF SCRIPT : Using updated location :"`echo "$serverUrl" | sed -ne 's/\/'"$firmwareFilename.*"'//p'` 
                    echo_t "XCONF SCRIPT : Version  :"$firmwareVersion
                    echo_t "XCONF SCRIPT : Reboot   :"$rebootImmediately
                fi
                echo "$firmwareLocation" > /tmp/.xconfssrdownloadurl

                # Check if xconf returned any bundles to update
                # If so, trigger /etc/rdm/rdmBundleMgr.sh to process it
                if [ -n "$dlCertBundle" ]; then
                    echo_t "XCONF SCRIPT : Calling /etc/rdm/rdmBundleMgr.sh to process bundle update" >> $XCONF_LOG_FILE
                    (sh /etc/rdm/rdmBundleMgr.sh "$dlCertBundle" "$firmwareLocation" >> ${LOG_PATH}/rdm_status.log 2>&1) &
                    echo_t "XCONF SCRIPT : /etc/rdm/rdmBundleMgr.sh started in background" >> $XCONF_LOG_FILE
                fi

           	# Check if a newer version was returned in the response
            # If image_upg_avl = 0, retry reconnecting with XCONf in next window
            # If image_upg_avl = 1, download new firmware 
                checkFirmwareUpgCriteria  
                echo "$firmwareLocation" > /tmp/.xconfssrdownloadurl

                if [ $image_upg_avl -eq 1 ] && [ $delayDownload -ne 0 ] && [ "$triggeredFrom" != "delayedDownload" ];
                then
                    cp $OUTPUT $LAST_HTTP_RESPONSE
                    echo "curr_conn_type|$curr_conn_type" >> $LAST_HTTP_RESPONSE

                    now=$(date +"%T")
                    SchedAtHr=$(echo $now | cut -d':' -f1)
                    SchedAtMin=$(echo $now | cut -d':' -f2)
                    Sec=$(echo $now | cut -d':' -f3)

                    if [ $Sec -gt 29 ]; then
                        SchedAtMin=`expr $SchedAtMin + 1`
                    fi

                    SchedAtMin=`expr $SchedAtMin + $delayDownload`
                    while [ $SchedAtMin -gt 59 ]
                    do
                        SchedAtMin=`expr $SchedAtMin - 60`
                        SchedAtHr=`expr $SchedAtHr + 1`
                        if [ $SchedAtHr -gt 23 ]; then
                            SchedAtHr=0
                        fi
                    done

                    echo_t "XCONF SCRIPT : current Time: $now, download scheduled at $SchedAtHr:$SchedAtMin" >> $XCONF_LOG_FILE
                    crontab -l -c $CRONTAB_DIR > $CRON_FILE_BK
                    SCRIPT_NAME=${0##*/}
                    sed -i "/[A-Za-z0-9]*$SCRIPT_NAME 5 */d" $CRON_FILE_BK
                    echo "$SchedAtMin $SchedAtHr * * * /etc/$SCRIPT_NAME 5" >> $CRON_FILE_BK
                    crontab $CRON_FILE_BK -c $CRONTAB_DIR
                    rm -rf $CRON_FILE_BK
                    exit
                fi
	      fi
		
        # If a response code of 404 was received, exit
        elif [ $HTTP_RESPONSE_CODE -eq 404 ]; then
            retry_flag=0
            image_upg_avl=0
            echo_t "XCONF SCRIPT : Response code received is 404" >> $XCONF_LOG_FILE
            if [ "$DEVICE_MODEL" = "TCHXB3" ]; then
                echo_t "XCONF SCRIPT : Creating /tmp/.xconfssrdownloadurl with $HTTP_RESPONSE_CODE Xconf response"  >> $XCONF_LOG_FILE
                echo "404" > /tmp/.xconfssrdownloadurl
            fi
            exit
        # If a response code of 0 was received, the server is unreachable
        # Try reconnecting
        else
            retry_flag=1
            image_upg_avl=0

            if [ $xconf_retry_count -lt $((CONN_TRIES - 1)) ]; then
                if [ "$curr_conn_type" = "direct" ]; then
                    sleep_time=120
                elif [ "$xconf_retry_count" -eq "0" ]; then
                    sleep_time=10
                else
                    sleep_time=30
                fi
                echo_t "XCONF SCRIPT : Retrying query in $sleep_time seconds" >> $XCONF_LOG_FILE
                    sleep $sleep_time
            fi
            #Increment the retry count
            xconf_retry_count=$((xconf_retry_count+1))
        fi
        interface=$(getWanInterfaceName)

    done

    # If try for CONN_TRIES times done and image is not available, then exit
    # Cron scheduled job will be triggered later
    if [ $xconf_retry_count -ge $CONN_TRIES ] && [ $image_upg_avl -eq 0 ]
    then
        if [ "$curr_conn_type" != "direct" ]; then
            [ -f $CODEBIG_BLOCK_FILENAME ] || touch $CODEBIG_BLOCK_FILENAME
            touch $FORCE_DIRECT_ONCE
        fi
        echo_t "XCONF SCRIPT : Retry limit to connect with XCONF server reached, so exit" 
        exit
    fi
}

#Fetch firmware name and location from last saved response.
fetchFirmwareDetail()
{
    #Firmware download delay timer expired. Remove it from cron.
    SCRIPT_NAME=${0##*/}
    crontab -l -c $CRONTAB_DIR > $CRON_FILE_BK
    sed -i "/[A-Za-z0-9]*$SCRIPT_NAME 5 */d" $CRON_FILE_BK
    crontab $CRON_FILE_BK -c $CRONTAB_DIR
    rm -rf $CRON_FILE_BK

    if [ ! -e $LAST_HTTP_RESPONSE ]; then
        echo_t "XCONF SCRIPT : Last saved file not available" >> $XCONF_LOG_FILE
        return
    fi

    echo_t "XCONF SCRIPT : Fetching firmware details from last saved response" >> $XCONF_LOG_FILE

    firmwareDownloadProtocol=`grep firmwareDownloadProtocol $LAST_HTTP_RESPONSE  | cut -d \| -f2`
    firmwareLocation=`grep firmwareLocation $LAST_HTTP_RESPONSE | cut -d \| -f2 | tr -d ' '`
    firmwareFilename=`grep firmwareFilename $LAST_HTTP_RESPONSE | cut -d \| -f2`

    if [ -z "$firmwareLocation" ] || [ -z "$firmwareFilename" ]; then
        echo_t "XCONF SCRIPT : Fetch firmware upgrade details from Xconf" >> $XCONF_LOG_FILE
        return
    fi

    firmwareVersion=`grep firmwareVersion $LAST_HTTP_RESPONSE | cut -d \| -f2`
    ipv6FirmwareLocation=`grep ipv6FirmwareLocation $LAST_HTTP_RESPONSE | cut -d \| -f2 | tr -d ' '`
    delayDownload=`grep delayDownload $LAST_HTTP_RESPONSE | cut -d \| -f2`
    rebootImmediately=`grep rebootImmediately $LAST_HTTP_RESPONSE | cut -d \| -f2`
    curr_conn_type=`grep curr_conn_type $LAST_HTTP_RESPONSE | cut -d \| -f2`
    factoryResetImmediately=`grep factoryResetImmediately $LAST_HTTP_RESPONSE | cut -d \| -f2`

    image_upg_avl=1;

    if [ "$curr_conn_type" != "direct" ]; then
        serverUrl=""
        authorizationHeader=""
        imageHTTPURL="$firmwareLocation/$firmwareFilename"
        domainName=`echo $imageHTTPURL | awk -F/ '{print $3}'`
        imageHTTPURL=`echo $imageHTTPURL | sed -e "s|.*$domainName||g"`
        do_Codebig_signing "SSR"
    fi
}
set_maintenance_time()
{
    # To set default time
    # Extract maintenance window start and end time
    start_time=0
    end_time=0
    if [ -f "$FW_START" ] && [ -f "$FW_END" ]
    then
      start_time=`cat $FW_START`
      end_time=`cat $FW_END`
    fi

    if [ "$start_time" = "$end_time" ]
    then
        echo_t "XCONF SCRIPT : Start time can not be equal to end time" >> $XCONF_LOG_FILE
        t2CountNotify "Test_StartEndEqual"
        echo_t "XCONF SCRIPT : Resetting values to default" >> $XCONF_LOG_FILE
        start_time=3600
        end_time=14400
        echo "$start_time" > $FW_START
        echo "$end_time" > $FW_END
    fi
}

calcRandTime()
{
    rand_hr=0
    rand_min=0
    rand_sec=0

    # Calculate random min
    rand_min=`awk -v min=0 -v max=59 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

    # Calculate random second
    rand_sec=`awk -v min=0 -v max=59 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`
    
    set_maintenance_time
        # Generate time to check for update
    #
    if [ $1 -eq '1' ]; then
        
        echo_t "XCONF SCRIPT : Check Update time being calculated within 24 hrs."
        echo_t "XCONF SCRIPT : Check Update time being calculated within 24 hrs." >> $XCONF_LOG_FILE

        # Calculate random hour
        # The max random time can be 23:59:59
        rand_hr=`awk -v min=0 -v max=23 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

        echo_t "XCONF SCRIPT : Time Generated : $rand_hr hr $rand_min min $rand_sec sec"
        min_to_sleep=$(($rand_hr*60 + $rand_min))
        sec_to_sleep=$(($min_to_sleep*60 + $rand_sec))

        printf "XCONF SCRIPT : Checking update with XCONF server at \t";
        # date -d "$min_to_sleep minutes" +'%H:%M:%S'
        date -d @"$(( `date +%s`+$sec_to_sleep ))"

        date_upgch_part="$(( `date +%s`+$sec_to_sleep ))"
        date_upgch_final=`date -d @"$date_upgch_part"`

        echo_t "Checking update on $date_upgch_final" >> $XCONF_LOG_FILE

    fi

    #
    # Generate time to downlaod HTTP image
    # device reboot time 
    #


    echo_t "XCONF SCRIPT : SLEEPING FOR $min_to_sleep minutes or $sec_to_sleep seconds"
    echo_t "XCONF SCRIPT : SLEEPING FOR $min_to_sleep minutes or $sec_to_sleep seconds" >> $XCONF_LOG_FILE
    
    #echo "XCONF SCRIPT : SPIN 17 : sleeping for 30 sec, *******TEST BUILD***********"
    #sec_to_sleep=30

    sleep $sec_to_sleep
    echo "XCONF script : got up after $sec_to_sleep seconds"
    echo_t "XCONF script : got up after $sec_to_sleep seconds" >> $XCONF_LOG_FILE
}

# Get the MAC address of the WAN interface
getMacAddress()
{
    ifconfig  | grep $wan_interface |  grep -v $wan_interface:0 | tr -s ' ' | cut -d ' ' -f5
}

getBuildType()
{
   IMAGENAME=`grep imagename /fss/gw/version.txt | cut -d ":" -f 2`

   TEMPDEV=`echo $IMAGENAME | grep DEV`
   if [ "$TEMPDEV" != "" ]
   then
       type="DEV"
   fi

   TEMPVBN=`echo $IMAGENAME | grep VBN`
   if [ "$TEMPVBN" != "" ]
   then
       type="VBN"
   fi

   TEMPPROD=`echo $IMAGENAME | grep PROD`
   if [ "$TEMPPROD" != "" ]
   then
       type="PROD"
   fi

   TEMPCQA=`echo $IMAGENAME | grep CQA`
   if [ "$TEMPCQA" != "" ]
   then
       type="GSLB"
   fi
   
   echo_t "XCONF SCRIPT : image_type is $type"
   echo_t "XCONF SCRIPT : image_type is $type" >> $XCONF_LOG_FILE
}

 
removeLegacyResources()
{
	#moved Xconf logging to /var/tmp/xconf.txt.0
    if [ -f /etc/Xconf.log ]; then
		rm /etc/Xconf.log
    fi

	echo_t "XCONF SCRIPT : Done Cleanup"
	echo_t "XCONF SCRIPT : Done Cleanup" >> $XCONF_LOG_FILE
}


#####################################################Main Application#####################################################

# Determine the env type and url and write to /tmp/Xconf
#type=`printenv model | cut -d "=" -f2`

removeLegacyResources
getBuildType
set_maintenance_time

# Check triggerType
triggeredFrom=""
if [[ $1 -eq 5 ]]; then
    echo_t "XCONF SCRIPT : Trigger from delayDownload Timer" >> $XCONF_LOG_FILE
    triggeredFrom="delayedDownload"
elif [[ $1 -eq 1 ]]; then
    triggeredFrom="bootup"
else
    echo_t "XCONF SCRIPT : Trigger is Unknown. Set it to boot" >> $XCONF_LOG_FILE
    triggeredFrom="boot"
fi

# If unit is waiting for reboot after image download,we need not have to download image again.
if [ -f $REBOOT_WAIT ]
then
    echo "XCONF SCRIPT : Waiting reboot after download, so exit" >> $XCONF_LOG_FILE
    exit
fi

if [ -f $DOWNLOAD_INPROGRESS ]
then
    echo "XCONF SCRIPT : Download is in progress, exit" >> $XCONF_LOG_FILE
    exit
fi

echo_t XCONF SCRIPT : MODEL IS $type

#Default xconf url
url="https://xconf.xcal.tv/xconf/swu/stb/"
 
# Override mechanism should work only for non-production build.
if [ "$type" != "PROD" ] && [ "$type" != "prod" ]; then
  if [ -f /nvram/swupdate.conf ]; then
      url=`grep -v '^[[:space:]]*#' /nvram/swupdate.conf`
      echo_t "XCONF SCRIPT : URL taken from /nvram/swupdate.conf override. URL=$url"
      echo_t "XCONF SCRIPT : URL taken from /nvram/swupdate.conf override. URL=$url"  >> $XCONF_LOG_FILE
  else
      # RFC override should work only for non-production build
      url_override=`syscfg get AutoExcludedURL`
      if [ "$url_override" ] ; then
         url=$url_override
      fi
  fi
fi

echo_t "XCONF SCRIPT : Device retrieves firmware update from url=$url"

#s16 echo "$type=$url" > /tmp/Xconf
echo "URL=$url" > /tmp/Xconf
echo_t "XCONF SCRIPT : Values written to /tmp/Xconf are URL=$url"
echo_t "XCONF SCRIPT : Values written to /tmp/Xconf are URL=$url" >> $XCONF_LOG_FILE

# Check if the WAN interface has an ip address, if not , wait for it to receive one
estbIp=`ifconfig $interface | grep "inet addr" | tr -s " " | cut -d ":" -f2 | cut -d " " -f1`
estbIp6=`ifconfig $interface | grep "inet6 addr" | grep "Global" | tr -s " " | cut -d ":" -f2- | cut -d "/" -f1 | tr -d " "`

echo "[ $(date) ] XCONF SCRIPT - Check if the WAN interface has an ip address" >> $XCONF_LOG_FILE

while [ "$estbIp" = "" ] && [ "$estbIp6" = "" ]
do
    echo "[ $(date) ] XCONF SCRIPT - No IP yet! sleep(5)" >> $XCONF_LOG_FILE
    sleep 5
    interface=$(getWanInterfaceName)

    estbIp=`ifconfig $interface | grep "inet addr" | tr -s " " | cut -d ":" -f2 | cut -d " " -f1`
    estbIp6=`ifconfig $interface | grep "inet6 addr" | grep "Global" | tr -s " " | cut -d ":" -f2- | cut -d "/" -f1 | tr -d " "`

    echo_t "XCONF SCRIPT : Sleeping for an ipv4 or an ipv6 address on the $interface interface "
done

echo_t "XCONF SCRIPT : $interface has an ipv4 address of $estbIp or an ipv6 address of $estbIp6"

    ######################
    # QUERY & DL MANAGER #
    ######################
# Checking Autoupdate exclusion
FWUPGRADE_EXCLUDE=`syscfg get AutoExcludedEnabled`
if [ x$FWUPGRADE_EXCLUDE != "x" ];then
    echo_t "FWExclusion status is : $FWUPGRADE_EXCLUDE"
fi

# Triggered after delayedDownload timer expired
if [ "$triggeredFrom" = "delayedDownload" ];
then
   fetchFirmwareDetail
fi

# Check if new image is available
echo_t "XCONF SCRIPT : Checking image availability at boot up" >> $XCONF_LOG_FILE
if [ ! -e $NO_DOWNLOAD ] && [ $image_upg_avl -eq 0 ];
then	
   getFirmwareUpgDetail
fi

Retry_Reboot_count=0
if [ "$factoryResetImmediately" == "true" ];then
    echo_t "XCONF SCRIPT : factoryResetImmediately : TRUE!!" >> $XCONF_LOG_FILE
    echo_t "XCONF SCRIPT : firmwareLocation: $firmwareLocation firmwareFilename : $firmwareFilename" >> $XCONF_LOG_FILE
    while [ $Retry_Reboot_count -lt 3 ]; do
        $BIN_PATH/XconfHttpDl upgrade_factoryreset "$firmwareLocation" "$firmwareFilename" >> $XCONF_LOG_FILE
        reboot_device=$?
        if [ $reboot_device -eq 0 ];then
    	    echo_t "XCONF SCRIPT : factory resetting and upgrading the image" >> $XCONF_LOG_FILE
            break
        else
            echo_t "XCONF SCRIPT : Failed to upgrade and factory reset retrying...$Retry_Reboot_count" >> $XCONF_LOG_FILE
            Retry_Reboot_count=$((Retry_Reboot_count+1))
        fi
    done
    if [ $Retry_Reboot_count -eq 3 ];then
        echo_t "XCONF SCRIPT : Failed to upgrade after max 3 retires.. exiting !!!" >> $XCONF_LOG_FILE
    fi
    exit
fi

if [ "$rebootImmediately" == "true" ];then
    echo_t "XCONF SCRIPT : Reboot Immediately : TRUE!!"
else
    echo_t "XCONF SCRIPT : Reboot Immediately : FALSE."

fi    

download_image_success=0
reboot_device_success=0
http_flash_led_disable=0
http_flash_led_enable=1
is_already_flash_led_disable=0

while [ $download_image_success -eq 0 ]; 
do

    if [ -f $Downloaded ]
   then
    echo_t "XCONF SCRIPT : image already downloaded" >> $XCONF_LOG_FILE
    break
   fi
    #skip download if file exist
    if [ -f $NO_DOWNLOAD ]
    then
       break
    fi

    if [ ! -f $DOWNLOAD_INPROGRESS ]
    then
        touch $DOWNLOAD_INPROGRESS
    fi

    if [ $image_upg_avl -eq 1 ];then
       echo "$firmwareLocation" > /tmp/xconfdownloadurl
       echo_t "XCONF SCRIPT : HTTP SSR set for $curr_conn_type download"
       echo_t "XCONF SCRIPT : HTTP SSR set for $curr_conn_type download" >> $XCONF_LOG_FILE

       if [ "$curr_conn_type" = "direct" ]; then
          # Set the url and filename
          echo_t "XCONF SCRIPT : URL --- --tlsv1.2 $addr_type -fgL $firmwareLocation/$firmwareFilename and NAME --- $firmwareFilename" >> $XCONF_LOG_FILE
#          CURL_CMD_SSR="curl --connect-timeout 30 --tlsv1.2 --interface $interface $addr_type -w '%{http_code}\n' -fgLo $TMP_PATH/$firmwareFilename '$firmwareLocation/$firmwareFilename'"
          $BIN_PATH/XconfHttpDl set_http_url "$addr_type -fgL '$firmwareLocation/$firmwareFilename'" "$firmwareFilename" complete_url
          set_url_stat=$?
       else
          # Set the url and filename
          echo_t "XCONF SCRIPT : URL --- `echo "$addr_type $CURL_SSR_PARAM"| sed -e  's/oauth_consumer_key=.*oauth_signature=.*/<hidden>/g'` and NAME --- $firmwareFilename"
          echo_t "XCONF SCRIPT : URL --- `echo "$addr_type $CURL_SSR_PARAM"| sed -e  's/oauth_consumer_key=.*oauth_signature=.*/<hidden>/g'` and NAME --- $firmwareFilename" >> $XCONF_LOG_FILE
#          echo_t "Codebig CURL_CMD :`echo  "$CURL_CMD_SSR" |  sed -ne 's#'"$authorizationHeader"'#<Hidden authorization-header>#p'`"
          $BIN_PATH/XconfHttpDl set_http_url "$addr_type $CURL_SSR_PARAM" "$firmwareFilename" complete_url
          set_url_stat=$?
       fi
        
        # If the URL was correctly set, initiate the download
        if [ $set_url_stat -eq 0 ];then
        
            # An upgrade is available and the URL has ben set 
            # Wait to download in the maintenance window if the RebootImmediately is FALSE
            # else download the image immediately

            if [ "$rebootImmediately" == "false" ];then

				echo "XCONF SCRIPT : Reboot Immediately : FALSE. Downloading image now"
				echo_t "XCONF SCRIPT : Reboot Immediately : FALSE. Downloading image now" >> $XCONF_LOG_FILE
			if  [ $is_already_flash_led_disable -eq 0 ];
			then
				echo_t "XCONF SCRIPT	: ### Disabling httpdownload LED flash ###" >> $XCONF_LOG_FILE
				$BIN_PATH/XconfHttpDl http_flash_led $http_flash_led_disable
				 is_already_flash_led_disable=1
			fi    
            else
                echo  "XCONF SCRIPT : Reboot Immediately : TRUE : Downloading image now"
                echo_t  "XCONF SCRIPT : Reboot Immediately : TRUE : Downloading image now" >> $XCONF_LOG_FILE
			if  [ $is_already_flash_led_disable -eq 1 ];
			then
				echo_t "XCONF SCRIPT	: ### Enabling httpdownload LED flash ###" >> $XCONF_LOG_FILE
				$BIN_PATH/XconfHttpDl http_flash_led $http_flash_led_enable
				 is_already_flash_led_disable=0
			fi  
            fi
			
			#echo "XCONF SCRIPT : Sleep to prevent gw refresh error"
			#echo "XCONF SCRIPT : Sleep to prevent gw refresh error" >> $XCONF_LOG_FILE
            #sleep 60

		#Trigger FirmwareDownloadStartedNotification before commencement of firmware download

		current_time=`date +%s`
		echo_t "current_time calculated as $current_time" >> $XCONF_LOG_FILE
		if [ "$rebootImmediately" == "true" ];then
			reboot_flag="forced"
		else
			reboot_flag="deferred"
		fi
		FW_DWLD_NOTIFICATION_STRING="$current_time,$reboot_flag,$current_FW_Version,$update_FW_Version"
		echo_t "XCONF SCRIPT : FirmwareDownloadStartedNotification parameters are $FW_DWLD_NOTIFICATION_STRING" >> $XCONF_LOG_FILE
		dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.RPC.FirmwareDownloadStartedNotification string $FW_DWLD_NOTIFICATION_STRING
		echo_t "XCONF SCRIPT : FirmwareDownloadStartedNotification SET is triggered" >> $XCONF_LOG_FILE

	        # Start the image download
			echo "[ $(date) ] XCONF SCRIPT  ### httpdownload started ###" >> $XCONF_LOG_FILE
	        $BIN_PATH/XconfHttpDl http_download
	        http_dl_stat=$?
			echo "[ $(date) ] XCONF SCRIPT  ### httpdownload completed ###" >> $XCONF_LOG_FILE
	        echo "XCONF SCRIPT : HTTP DL STATUS $http_dl_stat"
	        echo_t "**XCONF SCRIPT : HTTP DL STATUS $http_dl_stat**" >> $XCONF_LOG_FILE
			
	        # If the http_dl_stat is 0, the download was succesful,          
            # Indicate a succesful download and continue to the reboot manager
		
            if [ $http_dl_stat -eq 0 ];then
                echo_t "XCONF SCRIPT : HTTP download Successful" >> $XCONF_LOG_FILE
		t2CountNotify "XCONF_Dwld_success"
                # Indicate succesful download
                download_image_success=1
                if [ "$triggeredFrom" == "bootup" ]; then
                    touch $Downloaded
                fi
                rm -rf $DOWNLOAD_INPROGRESS
            else
                # Indicate an unsuccesful download
                echo_t "XCONF SCRIPT : HTTP download NOT Successful" >> $XCONF_LOG_FILE
		t2CountNotify "XCONF_Dwld_failed"
                rm -rf $DOWNLOAD_INPROGRESS
                download_image_success=0
                # Set the flag to 0 to force a requery
                image_upg_avl=0
			    # No need of looping here as we will trigger a cron job at random time
			    exit
           fi

		#Trigger FirmwareDownloadCompletedNotification after firmware download
		# true indicates successful download and false indicates unsuccessful download.
		if [ $http_dl_stat -eq 0 ];then
			dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.RPC.FirmwareDownloadCompletedNotification bool true
			echo_t "FirmwareDownloadCompletedNotification SET to true is triggered" >> $XCONF_LOG_FILE
		else
			dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.RPC.FirmwareDownloadCompletedNotification bool false
			echo_t "FirmwareDownloadCompletedNotification SET to false is triggered" >> $XCONF_LOG_FILE
		fi


       else
                download_image_success=0
            	# Set the flag to 0 to force a requery
            	image_upg_avl=0
                rm -rf $DOWNLOAD_INPROGRESS
          	   retry_download=`expr $retry_download + 1`
		       
        	   if [ $retry_download -eq 3 ]
          	   then
             	       echo_t "XCONF SCRIPT : ERROR : URL & Filename not set correctly after 3 retries.Exiting" >> $XCONF_LOG_FILE
        	       exit  
          	   fi
       fi
    fi
done

    ##################
    # REBOOT MANAGER #
    ##################

    # Try rebooting the device if :
    # 1. Issue an immediate reboot if still within the maintenance window and phone is on hook
    # 2. If an immediate reboot is not possile ,calculate and remain within the reboot maintenance window
    # 3. The reboot ready status is OK within the maintenance window 
    # 4. The rebootImmediate flag is set to true
Retry_count=0
while [ $reboot_device_success -eq 0 ]; do
                    
    # Verify reboot criteria ONLY if rebootImmediately is FALSE
    if [ "$rebootImmediately" == "false" ];then

        set_maintenance_time
        
        if [ "$triggeredFrom" == "bootup" ]; then
            echo_t "XCONF SCRIPT :reboot in cron scheduler trigger as it is bootup case" >> $XCONF_LOG_FILE
            exit
        fi

        Retry_count=$((Retry_count+1))
        if [ $Retry_count -eq 3 ];then
        echo_t "XCONF SCRIPT : Reboot failed after 3 retries.. exiting" >> $XCONF_LOG_FILE
        touch $Downloaded
        exit
        fi

        # Check the Reboot status
        # Continously check reboot status every 10 seconds  
        # till the end of the maintenace window until the reboot status is OK
        $BIN_PATH/XconfHttpDl http_reboot_status
        http_reboot_ready_stat=$?

    else
        #RebootImmediately is TRUE
        echo_t "XCONF SCRIPT : Reboot Immediately : TRUE!, rebooting device now"
        http_reboot_ready_stat=0    
        echo_t "XCONF SCRIPT : http_reboot_ready_stat is $http_reboot_ready_stat"
                            
    fi 
                    
    echo_t "XCONF SCRIPT : http_reboot_ready_stat is $http_reboot_ready_stat" >> $XCONF_LOG_FILE

    # The reboot ready status changed to OK within the maintenance window,proceed
    if [ $http_reboot_ready_stat -eq 0 ];then

 	if [ $abortReboot_count -lt 5 ];then
		#Wait for Notification to propogate
		deferfw=`dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.RPC.DeferFWDownloadReboot | grep value | cut -d ":" -f 3 | tr -d ' ' `
		echo_t "XCONF SCRIPT : Sleeping for $deferfw seconds before reboot" >> $XCONF_LOG_FILE
		touch $deferReboot 
		dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.RPC.RebootPendingNotification uint $deferfw
		sleep $deferfw
	else
		echo_t "XCONF SCRIPT : Abort Count reached maximum limit $abortReboot_count" >> $XCONF_LOG_FILE
	fi

        #Abort Reboot
	if [ ! -e "$ABORT_REBOOT" ]
	then

	if [ "x$isWanLinkHealEnabled" == "xtrue" ];then
	    /usr/ccsp/tad/check_gw_health.sh store-health
	fi
    if [ "$rebootImmediately" == "false" ];then
        RFC_STATUS=`sysevent get RFC_Execution`
        if [ "$RFC_STATUS" = "" ] || [ "$RFC_STATUS" !=  "Completed" ]
        then
            event_retry_count=0
            while [ $event_retry_count -lt 3 ]; do
                RFC_STATUS=`sysevent get RFC_Execution`
                # Rfc execution status is not null, checking whether it is completed,if not completed
                # wait for 5 min to complete.
                if [ "$RFC_STATUS" != "" ]; then
                    echo_t "XCONF SCRIPT : $RFC_STATUS not equal to null, checking completion status" >> $XCONF_LOG_FILE
                    if [ "$RFC_STATUS" !=  "Completed" ]; then
                        echo_t "XCONF SCRIPT : Sleeping for 5 mins for rfc completion " >> $XCONF_LOG_FILE
                        sleep 300
                        break
                    elif [ "$RFC_STATUS" =  "Completed" ]; then
                        echo_t "XCONF SCRIPT : Breaking the rfc event check loop and continuing the script as rfc execution completed " >> $XCONF_LOG_FILE
                        break
                    fi    
                else
                    event_retry_count=$((event_retry_count+1))
                    echo_t "XCONF SCRIPT : Retrying for rfc status $event_retry_count" >> $XCONF_LOG_FILE
                fi
            done
        fi
    fi
        #Reboot the device
	    echo_t "XCONF SCRIPT : Reboot possible. Issuing reboot command"
	    echo_t "RDKB_REBOOT : Reboot command issued from XCONF"
		echo_t "setting LastRebootReason"
		dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_LastRebootReason string Software_upgrade
		echo_t "XCONF SCRIPT : SET succeeded"
		$BIN_PATH/XconfHttpDl http_reboot 
		reboot_device=$?
		       
        # This indicates we're within the maintenace window/rebootImmediate=TRUE
        # and the reboot ready status is OK, issue the reboot
        # command and check if it returned correctly
		if [ $reboot_device -eq 0 ];then
            reboot_device_success=1
		     #For rdkb-4260
		    echo_t "Creating file /nvram/reboot_due_to_sw_upgrade"
		    touch /nvram/reboot_due_to_sw_upgrade
		    echo_t "XCONF SCRIPT : REBOOTING DEVICE"
            echo_t "RDKB_REBOOT : Rebooting device due to software upgrade"
                
        else 
            # The reboot command failed, retry in the next maintenance window 
            reboot_device_success=0
            #Goto start of Reboot Manager again 
            fi
        else
                echo_t "XCONF SCRIPT : Reboot aborted by user, will try in next maintenance window "
		        abortReboot_count=$((abortReboot_count+1))
		        echo_t "XCONF SCRIPT : Abort Count is  $abortReboot_count" >> $XCONF_LOG_FILE
       	        touch $NO_DOWNLOAD
                rm -rf $ABORT_REBOOT
                rm -rf $deferReboot
                reboot_device_success=0
        fi

     # The reboot ready status didn't change to OK within the maintenance window 
     else
        reboot_device_success=0
        echo_t " XCONF SCRIPT : Device is not ready to reboot : Retrying !!";
        # Goto start of Reboot Manager again  
     fi
                    
done # While loop for reboot manager
