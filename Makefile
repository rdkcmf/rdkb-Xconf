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
include $(CCSP_ROOT_DIR)/arch/ccsp_common.mk

#
#	Set up include directories
#

INCPATH += $(CCSP_ROOT_DIR)/hal/include

CFLAGS += $(addprefix -I, $(INCPATH))


LDFLAGS += -lccsp_common

#
#	Xconf 
#

source_files := $(call add_files_from_src,,'*.c')
obj_files := $(addprefix $(ComponentBuildDir)/, $(source_files:%.c=%.o))


target := $(ComponentBuildDir)/XconfHttpDl

-include $(obj_files:.o=.d)

$(target): $(obj_files)


#
#	Build targets
#
all: $(target)

.PHONY: all clean

clean:
	rm -Rf $(ComponentBuildDir)

install_targets := $(target)
# config directories from both arch and arch/board
install_targets += $(wildcard $(ComponentArchCfgDir)/*)
install_targets += $(wildcard $(ComponentBoardCfgDir)/*)
install_targets += $(wildcard $(ComponentBoardScriptsDir)/*)


install:
	@echo "Installing XConf Installables"
	@install -d -m 0755 $(CCSP_OUT_DIR)
	@cp $(install_targets) $(CCSP_OUT_DIR)
	cp -f arch/intel_usg/boards/arm_shared/scripts/xb3_firmwareDwnld.sh $(TARGET_HOME)/build/vgwsdk/fs/base_fs/etc
#
# include custom post makefile, if exists
#
ifneq ($(findstring $(CCSP_CMPNT_BUILD_CUSTOM_MK_POST), $(wildcard $(ComponentBoardDir)/*.mk)), )
    include $(ComponentBoardDir)/$(CCSP_CMPNT_BUILD_CUSTOM_MK_POST)
endif
