/*
 * If not stated otherwise in this file or this component's Licenses.txt file the
 * following copyright and licenses apply:
 *
 * Copyright 2017 RDK Management
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
*/
#include <stdio.h>
#include <unistd.h>
#include <string.h>

#include <telemetry_busmessage_sender.h>


#include "cm_hal.h"

#if defined(_ENABLE_EPON_SUPPORT_)
#include "dpoe_hal.h"
#endif

#define RETRY_HTTP_DOWNLOAD_LIMIT 3
#define RETURN_OK 0
#define LONG long
#define CM_HTTPURL_LEN 1024
#define CM_FILENAME_LEN 200
/*Typedefs Declared*/

/*Global Definitions*/
int retry_limit = 0;


INT Set_HTTP_Download_Url(char *pHttpUrl, char *pfilename) {
        int ret_stat = 0;
        char pGetHttpUrl[CM_HTTPURL_LEN] = {'0'};
        char pGetFilename[CM_FILENAME_LEN] = {'0'};

        /*Set the HTTP download URL*/
#ifdef FEATURE_FWUPGRADE_MANAGER
        ret_stat = fwupgrade_hal_set_download_url(pHttpUrl, pfilename);
#else
	ret_stat = cm_hal_Set_HTTP_Download_Url(pHttpUrl, pfilename);
#endif
        if (ret_stat == RETURN_OK) {
                // zero out pGetHttpUril and pGetFilename before calling fwupgrade_hal_get_download_Url()
                memset(pGetHttpUrl, 0, CM_HTTPURL_LEN);
                memset(pGetFilename, 0, CM_FILENAME_LEN);
                /*Get the status of the set above*/
#ifdef FEATURE_FWUPGRADE_MANAGER
                ret_stat = fwupgrade_hal_get_download_url(pGetHttpUrl, pGetFilename);
#else
                ret_stat = cm_hal_Get_HTTP_Download_Url(pGetHttpUrl, pGetFilename);
#endif
                if (ret_stat == RETURN_OK)
                    printf("\nXCONF BIN : URL has successfully been set\n");
                else
                    printf("\nXCONF BIN : HTTP url GET error");

        } else {
            printf("\nXCONF BIN : HTTP url SET error");
        }

        return ret_stat;
}

INT HTTP_Download ()
{   
    int ret_stat;
    int http_dl_status=0;
    int retry_http_status=1;
    int retry_http_dl=1;
    FILE *log_wget = NULL;

    /* interface=0 for wan0, interface=1 for erouter0 */
    unsigned int interface=1;

    /*Set the download interface*/
    printf("\nXCONF BIN : Setting download interface to %d",interface);
#ifdef FEATURE_FWUPGRADE_MANAGER
    fwupgrade_hal_set_download_interface(interface);
#else
    cm_hal_Set_HTTP_Download_Interface(interface);
#endif
    while((retry_limit < RETRY_HTTP_DOWNLOAD_LIMIT) && (retry_http_dl==1))
    {
#ifdef FEATURE_FWUPGRADE_MANAGER
            ret_stat = fwupgrade_hal_download ();
#else
            ret_stat = cm_hal_HTTP_Download ();
#endif
            /*If the HTTP download started succesfully*/
            if(ret_stat == RETURN_OK)
            {
                printf("\nXCONF BIN : HTTP download started\n");
                /*
                 * Continue to get the download status if the retry_http_status flag is set,
                 * implying the image is being downloaded and disable the retry_http_dl flag.
                 *
                 * Stop getting the image download status, if the download was succesfull or
                 * if an error was received, in which case retry the http download
                 */
                
                /*
                 * Sleeping since the status returned is 
                 * 500 on immediate status query
                 */
                printf("\nXCONF BIN : Sleeping to prevent 500 error"); 
                sleep(10);

                
                /* Check if the /tmp/wget.log file was created, if not wait an adidtional time
                */
                log_wget= fopen("/tmp/wget.log", "r");

                if (log_wget == NULL) 
                {
                    printf("\n XCONF BIN : /tmp/wget.log doesn't exist. Sleeping an additional 10 seconds");
                    sleep(10);
                }
                else 
                {
                    fclose(log_wget);
                    printf("XCONF BIN : /tmp/wget.log created . Continue ...\n");
                }


                while(retry_http_status ==1)
                {    
                    /*Get the download status till SUCCESS*/
#ifdef FEATURE_FWUPGRADE_MANAGER
                    http_dl_status = fwupgrade_hal_get_download_status();
#else
                    http_dl_status = cm_hal_Get_HTTP_Download_Status();
#endif
                    /*Download completed succesfully*/
                    if(http_dl_status ==200)
                    {
                        printf("\nXCONF BIN : HTTP download COMPLETED with status : %d\n",http_dl_status);
                        retry_http_status=0;
                        retry_http_dl=0;

                        //printf("\nBIN : retry_http_status : %d",retry_http_status);
                        //printf("\nBIN : retry_dl_status : %d",retry_http_dl);

                    }
                    
                    else if (http_dl_status == 0)
                    {

                        printf("\nXCONF BIN : HTTP download is waiting to start with status : %d",http_dl_status);
                        
                        retry_http_dl=0;    
                        
                        sleep(5);
                        
                    }        
                    else if((http_dl_status>0)&&(http_dl_status<=100))
                    {   
                        //This is already set to 1
                        //retry_http_status=1;
                        retry_http_dl=0;

                        printf("\nXCONF BIN : HTTP download in PROGRESS with status :  %d%%",http_dl_status);
                        
                        sleep(2);
                    }
                

                    /* If an error is received, fail the HTTP download
                     * It will be retried in the next window
                     */
		    else if (http_dl_status > 400)
		    {
			    retry_http_dl=0;
			    retry_http_status=0;
		    }
                            
                }
                          
            }//If condition

            /* If the HTTP download status returned with an error, 
             * a download was already in progress, 
             * retry after sleep
             */
            else
            {
                printf("\nXCONF BIN : HTTP Download not started. Retrying download after some time"); 

                /*This is to indicate that the actual download never started
                since a secondary download never ended or there was an error*/
                
                http_dl_status =-1;

                retry_http_dl=1;
                retry_limit++;
                sleep(10);
            }

    }//While condition 

    /*
     * The return status can either be
     * 200  : The download was succesful
     * >400 : An error was encountered . Retry in the next HTTP download window.
     * -1   : The actual http dl never started due to a secondary dl in progress or the primary dl not starting
     */
    if ((http_dl_status > 400) || (http_dl_status == -1))
    {
	    printf("\nXCONF BIN : HTTP DOWNLOAD ERROR with status : %d. Exiting.",http_dl_status);
	    if(http_dl_status == 500)
	    {
		    //"header": "SYS_INFO_FW_Dwld_500Error", "content": "HTTP download ERROR with status : 500", "type": "ArmConsolelog.txt.0"
		    t2_event_d("SYS_INFO_FW_Dwld_500Error",1);
	    }
	    t2_event_d("XCONF_Dwnld_error",1);
    }

    return http_dl_status;  
    
}
	

INT Reboot_Ready(LONG *pValue)
{
    int reboot_ready_status;
#if defined(_ENABLE_EPON_SUPPORT_)
    reboot_ready_status = dpoe_hal_Reboot_Ready(pValue);
#else
#ifdef FEATURE_FWUPGRADE_MANAGER
    reboot_ready_status = fwupgrade_hal_reboot_ready(pValue);
#else
    reboot_ready_status = cm_hal_Reboot_Ready(pValue);
#endif
#endif
    return reboot_ready_status;    
}

INT HTTP_Download_Reboot_Now ()
{
int http_reboot_stat; 
#ifdef FEATURE_FWUPGRADE_MANAGER
http_reboot_stat= fwupgrade_hal_download_reboot_now();
#else
http_reboot_stat= cm_hal_HTTP_Download_Reboot_Now();
#endif
if(http_reboot_stat == RETURN_OK)
    printf("\nXCONF BIN : Rebooting the device now!\n");

else
    printf("\nXCONF BIN : Reboot in progress. ERROR!\n");

return  http_reboot_stat;       
}

INT HTTP_LED_Flash ( int LEDFlashState )
{
	int http_led_flash_stat = -1; 

#ifdef HTTP_LED_FLASH_FEATURE
#ifdef FEATURE_FWUPGRADE_MANAGER
	http_led_flash_stat= fwupgrade_hal_led_flash( LEDFlashState );
#else
        http_led_flash_stat= cm_hal_HTTP_LED_Flash( LEDFlashState );
#endif
	if(http_led_flash_stat == RETURN_OK)
	{
	    printf("\nXCONF BIN : setting LED flashing completed! %d\n", LEDFlashState);
	}
	else
	{
	    printf("\nXCONF BIN : setting LED flashing completed. ERROR!\n");
	}
#else
		printf("\nXCONF BIN : Setting LED flashing not supported. ERROR!\n");
#endif /* HTTP_LED_FLASH_FEATURE */

	return  http_led_flash_stat;       
}

int main(int argc,char *argv[])
{

    char pHttpUrl[CM_HTTPURL_LEN] = {'0'};
    char pfilename[CM_FILENAME_LEN] = {'0'};

    LONG value = 0;
    int ret_code = 0;
    int http_status,reboot_status;
    int reset_device;
#if defined (_COSA_BCM_ARM_)
    int dl_status = 0;
#endif

    t2_init("ccsp-xconf");

	if(strcmp(argv[1],"set_http_url") == 0)
	{
            /*
             * End users of XconfHttpDl should not be impacted due to update in HAL api changes
             * New HAL apis using CURL needs exact location. Eg.:
             *      XconfHttpDl set_http_url http://download.server/image.bin image.bin
             */

             if (((argv[2]) != NULL) && ((argv[3]) != NULL)) {

                  strncpy(pfilename, argv[3], CM_FILENAME_LEN - 1);
                  if ((argv[4]) != NULL) {
                      if (strcmp(argv[4], "complete_url") == 0) {
                          // Exact download location passed by caller.
                          strncpy(pHttpUrl, argv[2], CM_HTTPURL_LEN - 1);
                          ret_code = Set_HTTP_Download_Url(pHttpUrl, pfilename);
                       } else {
                            printf("XCONF BIN : Unknown 3rd argument %s . Failed to complete set_http_url operation.\n", argv[4]);
                       }
                  } else {
                      // TBD - Evaluate impact on all other platforms which doesn't have changes in oem HAL api
                      // Form complete download URL from args passed by caller including the quotes
                      // "'" + pHttpUrl + "/" + "pfilename" + "'"
                      strcpy(pHttpUrl, "'");
                      strncat(pHttpUrl, argv[2], CM_HTTPURL_LEN - 1);
                      strcat(pHttpUrl, "/");
                      strncat(pHttpUrl, pfilename, CM_HTTPURL_LEN - 1);
                      strcat(pHttpUrl, "'");
                      ret_code = Set_HTTP_Download_Url(pHttpUrl, pfilename);
                  }

            }

	}

	else if (strcmp(argv[1],"http_download")==0)
	{
		http_status = HTTP_Download();

	    // The return code is after RETRY_HTTP_DOWNLOAD_LIMIT has been reached
        // For 200, return SUCCESS, else FAILURE and retry in the next window
		if(http_status == 200)
			ret_code = 0;

		else
			ret_code = 1;

	}

	else if (strcmp(argv[1],"http_reboot_status")==0)
	{

		reboot_status = Reboot_Ready(&value);
		printf("XCONF BIN : Reboot_Ready status %ld \n", value);
		if(reboot_status == RETURN_OK && value == 1)
			ret_code = 0;

		else
			ret_code= 1;
	}

	else if(strcmp(argv[1],"http_reboot")==0)
	{
		reset_device = HTTP_Download_Reboot_Now();

			if(reset_device == RETURN_OK)
				ret_code = 0;

			else
				ret_code= 1;
	}
	else if(strcmp(argv[1],"http_flash_led")==0)
	{
		if( argv[2] != NULL )
		{
			char LEDFlashState[ 24 ] = { 0 };

			strncpy( LEDFlashState, argv[2], sizeof( LEDFlashState ) - 1 );
			
			reset_device = HTTP_LED_Flash( atoi( LEDFlashState ) );
			
				if(reset_device == RETURN_OK)
					ret_code = 0;
				else
					ret_code= 1;
		}
	}
    else if(strcmp(argv[1],"upgrade_factoryreset")==0)
    {
        if (((argv[2]) != NULL) && ((argv[3]) != NULL))
        {
            strncpy(pfilename, argv[3], CM_FILENAME_LEN - 1);
            strncpy(pHttpUrl, argv[2], CM_HTTPURL_LEN - 1);
        }
        printf("XCONF BIN : upgrade_factoryreset calling cm_hal_FWupdateAndFactoryReset \n" );
        printf("XCONF BIN : URL: %s FileName %s \n", pHttpUrl, pfilename );
        reset_device = cm_hal_FWupdateAndFactoryReset( pHttpUrl, pfilename );
        printf("XCONF BIN : hal return value %d\n", reset_device);
        if(reset_device == RETURN_OK)
        {
            ret_code = 0;
#if defined (_COSA_BCM_ARM_)
            while(1)
            {
                dl_status = cm_hal_Get_HTTP_Download_Status();

                if(dl_status >= 0 && dl_status <= 100)
                    sleep(2);
                else if(dl_status == 200)
                    sleep(10);
                else if(dl_status >= 400)
                {
                    printf(" FW DL is failed with status %d \n", dl_status);
                    ret_code= 1;
                    break;
                }
            }
#endif
        }
        else
        {
            ret_code= 1;
        }

    }
    return ret_code;
}
