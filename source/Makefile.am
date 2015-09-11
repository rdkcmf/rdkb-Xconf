## Copyright (c) 2013 Comcast. All rights reserved.

AM_CPPFLAGS = -I$(top_srcdir)/hal/include
AM_CFLAGS = -D_COSA_SIM_ $(AM_CPPFLAGS)
AM_LDFLAGS = -lccsp_common
AM_LDFLAGS += -lhal_cm
lib_LTLIBRARIES = libXconf.la 
libXconf_la_SOURCES = cm_http_dl.c

