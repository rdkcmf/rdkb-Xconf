## Copyright (c) 2013 Comcast. All rights reserved.
bin_PROGRAMS = XconfHttpDl 
AM_CPPFLAGS = -I$(top_srcdir)/hal/include
AM_CFLAGS = -D_COSA_SIM_ $(AM_CPPFLAGS)
AM_LDFLAGS = -lccsp_common
AM_LDFLAGS += -lcm_mgnt
XconfHttpDl_SOURCES = cm_http_dl.c

