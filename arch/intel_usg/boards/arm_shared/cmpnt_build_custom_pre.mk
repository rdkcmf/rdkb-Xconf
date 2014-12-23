#######################################################################
#   Copyright [2014] [Cisco Systems, Inc.]
# 
#   Licensed under the Apache License, Version 2.0 (the \"License\");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
# 
#       http://www.apache.org/licenses/LICENSE-2.0
# 
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an \"AS IS\" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#######################################################################

#
#   for Intel USG, Pumba 6, all ARM boards
#   CM custom makefile
#

#
#   platform specific customization
#

LDFLAGS += -lpthread

HAL_LDFLAGS = -L$(CCSP_INSTALL_ROOT)/lib -lcm_mgnt
LDFLAGS += $(HAL_LDFLAGS)

DHCP_LDFLAGS = -L$(SDK_PATH)/ti/netdk/src/uipc
DHCP_LDFLAGS += -luipc -lapi_dhcpv4c
LDFLAGS += $(DHCP_LDFLAGS)

CM_LDFLAGS = -L$(SDK_PATH)/ti/lib 
CM_LDFLAGS += -lhal_db -lhal_global -lcmd_mbox
CM_LDFLAGS += -lhal_phy -lm -lmask_lib -lhal_reg_access
CM_LDFLAGS += -lus_db 
CM_LDFLAGS += -lhal_ds_calibration -lhal_tuner_api -lhal_ffs_calibration
CM_LDFLAGS += -lhal_us_calibration
CM_LDFLAGS += -lreinit_mac 
CM_LDFLAGS += -ldschannellistfreqdb -lprimary_ds_freq_override_db -lgetnextfreq
CM_LDFLAGS += -ldocsis_ext_interface -ldbridge_ctl -lcmstatus -ldmg_utils
CM_LDFLAGS += -lnvramstorage -lutils_docsis -lqos_internal_db -lfccfg -lti_sme -lsme
CM_LDFLAGS += -lhal_tuner_pwrSpec -lchdb_rx
LDFLAGS += $(CM_LDFLAGS)

# UTOPIA_LDFLAGS = -L$(SDK_PATH)/ti/lib -lutapi -lutctx -lsyscfg -lsysevent -lulog
# LDFLAGS += $(UTOPIA_LDFLAGS)
