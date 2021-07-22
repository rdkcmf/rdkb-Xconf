#!/bin/sh
##########################################################################
# If not stated otherwise in this file or this component's Licenses.txt
# file the following copyright and licenses apply:
#
# Copyright 2021 RDK Management
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

if [ -f /etc/device.properties ]; then
        source /etc/device.properties
fi

if [ "$DEVICE_TYPE" = "broadband" ]; then
        BUNDLE_METADATA_NVM_PATH="/nvram/etc/certs"
else
        BUNDLE_METADATA_NVM_PATH="/media/apps/etc/certs"
fi

BUNDLE_METADATA_RFS_PATH="/etc/certs"

JSONQUERY="/usr/bin/jsonquery"
PKG_METADATA_NAME="name"
PKG_METADATA_VER="version"
PKG_METADATA_LIST="contents"
PKG_METADATA_SIZE="size"
PKG_METADATA_INSTALL="installScript"


log()
{
        echo_t "$1" >> $XCONF_LOG_FILE
}


getPkgMetadata()
{
        data=$($JSONQUERY -f $1 -p $2)
        if [ $? -eq 0 ]; then
                echo "$data"
        else
                log "getPkgMetadata() failed to fetch $2"
                echo ""
        fi
}


### getInstalledBundleList
### Returns the list of bundles installed and its corresponding version
###
### Arguments:
### No arguments
###
### Return value:
### Type - string
### Format - "ABun:AVer,BBun:Bver"
getInstalledBundleList()
{
        metadata_nvm_ls=""
        metadata_rfs_ls=""

        if [ -d "$BUNDLE_METADATA_NVM_PATH" ]; then
                log "Fetching bundle metadata from $BUNDLE_METADATA_NVM_PATH"
                metadata_nvm_ls="$(find $BUNDLE_METADATA_NVM_PATH -name "*_package.json" -type f | tr '\n' ' ' | xargs)"
        else
                log "$BUNDLE_METADATA_NVM_PATH does not exist"
        fi

        if [ -d "$BUNDLE_METADATA_RFS_PATH" ]; then
                log "Fetching bundle metadata from $BUNDLE_METADATA_RFS_PATH"
                metadata_rfs_ls="$(find $BUNDLE_METADATA_RFS_PATH -name "*_package.json" -type f | tr '\n' ' ' | xargs)"
        else
                log "$BUNDLE_METADATA_RFS_PATH does not exist"
        fi

        if [ -z "$metadata_rfs_ls" -a -z "$metadata_nvm_ls" ]; then
                log "No metadata found in CPE"
                metadata_ls=""
        elif [ -z "$metadata_rfs_ls" ]; then
                log "Metadata found only in $BUNDLE_METADATA_NVM_PATH"
                metadata_ls="$metadata_nvm_ls"
        elif [ -z "$metadata_nvm_ls" ]; then
                log "Metadata found only in $BUNDLE_METADATA_RFS_PATH"
                metadata_ls="$metadata_rfs_ls"
        else
                log "Metadata found in both $BUNDLE_METADATA_NVM_PATH & $BUNDLE_METADATA_RFS_PATH"
                log "Preparing final matadata list"
                # Metadata present in nvram takes precendence over rootfs. Hence add rootfs metadata to final list
                # only when it is missing in nvram
                metadata_ls="$metadata_nvm_ls"
                for metadata in $metadata_rfs_ls; do
                        echo "$metadata_nvm_ls" | grep -q "$(basename $metadata)"
                        if [ $? -eq 0 ]; then
                                log "$(basename $metadata) already present in nvram"
                        else
                                log "$(basename $metadata) not present in nvram. Adding it to list"
                                metadata_ls="$metadata_ls $metadata"
                        fi
                done
        fi

        list=""
        if [ -n "$metadata_ls" ]; then
                log "List of bundle metadata found in CPE: $metadata_ls"
                for file in $metadata_ls; do
                        bundle_name=$(getPkgMetadata $file $PKG_METADATA_NAME)
                        bundle_version=$(getPkgMetadata $file $PKG_METADATA_VER)
                        if [ -n "$bundle_name" -o -n "$bundle_version" ]; then
                                list="$list $bundle_name:$bundle_version"
                        else
                                log "Missing package name or version in $file"
                        fi
                done
        fi

        if [ -n "$list" ]; then
                # Remove leading and trailing spaces if any
                bundle_list=$(echo $list | xargs | tr ' ' ',')
                log "Installed bundle list: $bundle_list"
        else
                log "Installed bundle list empty"
                bundle_list=""
        fi

        echo "$bundle_list"
}

