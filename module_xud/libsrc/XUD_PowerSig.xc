/** @file       XUD_PowerSig.xc
  * @brief      Functions for USB power signaling
  * @author     Ross Owen, XMOS Limited 
  **/

#include <xs1.h>
#include <print.h>

#include "xud.h"
#include "XUD_Support.h"
#include "XUD_UIFM_Functions.h"
#include "XUD_USB_Defines.h"
#include "XUD_UIFM_Defines.h"

#ifdef ARCH_S
#include "xa1_registers.h"
#include "glx.h"
extern unsigned get_tile_id(tileref ref);
extern tileref USB_TILE_REF;
#endif


void XUD_UIFM_PwrSigFlags();

#define T_WTRSTFS_us        26 // 26us
#define T_WTRSTFS            (T_WTRSTFS_us * REF_CLK_FREQ)
#define STATE_START_TO_us 3000 // 3ms
#define STATE_START_TO       (STATE_START_TO_us * REF_CLK_FREQ)
#define DELAY_6ms_us      6000
#define DELAY_6ms            (DELAY_6ms_us * REF_CLK_FREQ)

extern in  port p_usb_clk;
extern in  port reg_read_port;
extern in  port flag0_port;
extern in  port flag1_port;
extern in  port flag2_port;
extern out port p_usb_txd;
#ifdef ARCH_S
extern in buffered port:32 p_usb_rxd;
#define reg_read_port null
#define reg_write_port null
#else
extern out port reg_write_port;
extern port p_usb_rxd;
#endif
extern unsigned g_curSpeed;

/* Reset USB transceiver for specified time */
void XUD_PhyReset(out port p_rst, int time, unsigned rstMask)
{
    unsigned x;
    clearbuf(p_usb_rxd);

#ifndef ARCH_S
#warning TODO FIXME
    //p_usb_rxd <: 0;            // While in reset, drive 0 on data bus and clear port buffers
#endif   
    clearbuf(p_usb_rxd);
    
    x = peek(p_rst);
    x &= (~rstMask);
    p_rst <: x;

    XUD_Sup_Delay(time);

    x = peek(p_rst);
    x |= rstMask;
    p_rst <: x;
}

#define STATE_START 0
#define STATE_START_SE0 1
#define STATE_START_J 2
/* Initialise UIFM, setup UIFM for power-signaling and wait for host */
int XUD_Init()
{
    timer SE0_timer;
    unsigned SE0_start_time = 0;
    unsigned state = STATE_START;
    unsigned host_signal = 0;
    int tmp;
    int reset = 0;

#ifdef DO_TOKS
    /* Set default device address */
    XUD_UIFM_RegWrite(reg_write_port, UIFM_REG_ADDRESS, 0x0);
#endif

    /* Go into full speed mode: XcvrSelect and Term Select (and suspend) high */
    //XUD_UIFM_RegWrite(reg_write_port, UIFM_REG_PHYCON, 0x7);

    //XUD_Sup_Delay(18000);

    /* Wait for host */
    while (!host_signal)
    {
        switch (state)
        {
            case STATE_START:

#ifdef XUD_STATE_LOGGING
                addDeviceState(STATE_START_BEGIN);
#endif
                select
                {
                    /* SE0 State */
                    case flag2_port when pinseq(1) :> tmp:
                        state = STATE_START_SE0;
                        SE0_timer :> SE0_start_time;
                        break;

                    /* J State */
                    case flag0_port when pinseq(1) :> tmp:
                        state = STATE_START_J;
                        SE0_timer :> SE0_start_time;
                         break;
                }
                break;

            case STATE_START_SE0:

#ifdef XUD_STATE_LOGGING
            addDeviceState(STATE_SE0_BEGIN);
#endif

                select
                {
                    case flag2_port when pinseq(0) :> tmp:
                        state = STATE_START;
                        break;

                    case SE0_timer when timerafter(SE0_start_time + T_WTRSTFS) :> int:
                        host_signal = 1;
                        reset = 1;
                        break;
                }
                break;

          case STATE_START_J:
#ifdef XUD_STATE_LOGGING
            addDeviceState(STATE_J_BEGIN);
#endif
                select
                {
                    case flag0_port when pinseq(0) :> tmp:
                        state = STATE_START;
                        break;

                    case SE0_timer when timerafter(SE0_start_time + STATE_START_TO) :> int:
                        host_signal = 1;
                        
                        reset = 0;
                        break;
                }
                break;

        } /* switch */
    }

    /* Return 1 if reset */
    return reset;
}

extern int inSus;
extern unsigned susresettime;

#ifdef ARCH_S
#include <xa1_registers.h>
#endif
/** XUD_DoSuspend
  * @brief  Function called when device is suspended. This should include any clock down code etc.
  * @return True if reset detected during resume */
int XUD_Suspend()
{
    unsigned tmp;
    timer t;
    unsigned time;
    unsigned before;
    unsigned devAddr;

 
#if defined(ARCH_L) && defined(GLX_SUSPHY)
#ifdef GLX_PWRDWN
        XUD_UIFM_PwrSigFlags();

        /* NOTE CURRENTLY XEV DOES NOT GET TURNED OFF, WE JUST ARE USING SUSPEND CONTROLLER TO 
         * VERIFY FUNCTIONALITY */

        /* Wait for suspend J to make its way through filter */
        read_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_PHY_CONTROL_REG, before);

        while(1)
        {
            unsigned  x;
            read_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_PHY_TESTSTATUS_REG, x);
            x >>= 9;
            x &= 0x3;
            if(x == 1)
            {
                break;
            }
        }

        /* Save device address to Glx scratch*/
        {
            char wData[] = {0};
            read_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_DEVICE_ADDRESS_REG, devAddr);
            wData[0] = (char) devAddr;

            write_glx_periph_reg(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_SCTH_ID, 0x0, 0, 1,wData); 
        }
        
        /* Suspend Phy etc 
         * SEOFILTBASE sets a bit in a counter for anti-glitch (i.e 2 looks for change in 0b10)
         * This is a simple counter with check from wrap in this bit, so worst case could be x2 off
         * Counter runs at 32kHz by (31.25uS period). So setting 2 is about 63-125uS
         */
        write_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_PHY_CONTROL_REG, 
                                    (1 << XS1_UIFM_PHY_CONTROL_AUTORESUME) 
                                    |(0x2 << XS1_UIFM_PHY_CONTROL_SE0FILTVAL_BASE)
                                    | (1 << XS1_UIFM_PHY_CONTROL_FORCESUSPEND));

        /* Mark scratch reg */
        {
            char x[] = {1};
            write_glx_periph_reg(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_SCTH_ID, 0xff, 0, 1,x); 
        }

        // Finally power down Xevious,  keep sysclk running, keep USB enabled.
        write_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_PWR_ID, XS1_GLX_PWR_MISC_CTRL_ADRS, 
                       (1 << XS1_GLX_PWR_SLEEP_INIT_BASE)            /* Sleep */
                     | (1 << XS1_GLX_PWR_SLEEP_CLK_SEL_BASE)         /* Default clock */ 
                     | (0x3 << XS1_GLX_PWR_USB_PD_EN_BASE ) );       /* Enable usb power up/down */

        /* Normally XCore will now be off and will reboot on resume/reset 
         * However, all supplies enabled to test suspend controller so we'll poll resume reason reg.. */

        while(1)
        {
            unsigned wakeReason = 0;
            read_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_PHY_CONTROL_REG, wakeReason);
            
            if(wakeReason & (1<<XS1_UIFM_PHY_CONTROL_RESUMEK))
            {
                 
                /* Unsuspend phy */        
                write_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_PHY_CONTROL_REG,0);
                
                /* Wait for usb clock */
                p_usb_clk when pinseq(1) :> int _;
                p_usb_clk when pinseq(0) :> int _;
                p_usb_clk when pinseq(1) :> int _;
                p_usb_clk when pinseq(0) :> int _;              

                /* Func control reg will be default of 0x4 here term: 0 xcvSel: 0, opmode: 0b01 (non-driving) */

                write_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_FUNC_CONTROL_REG,
                            (1<<XS1_UIFM_FUNC_CONTROL_XCVRSELECT) 
                            | (1<<XS1_UIFM_FUNC_CONTROL_TERMSELECT));

                /* Set IFM to decoding linestate.. IFM regs reset when phy suspended */ 
                write_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_IFM_CONTROL_REG, 
                    (1<<XS1_UIFM_IFM_CONTROL_DECODELINESTATE)
                    | (1<< XS1_UIFM_IFM_CONTROL_SOFISTOKEN));

                XUD_UIFM_PwrSigFlags();
                
                write_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_DEVICE_ADDRESS_REG, devAddr);
                
                /* Wait for end of resume */
                while(1)
                {
                    /* Wait for se0 */
                    flag2_port when pinseq(1) :> void; 
                    
                    if(g_curSpeed == XUD_SPEED_HS)
                    {
                        /* Back to high-speed */
                        write_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_FUNC_CONTROL_REG, 0);
                    }
                    return 0;
                }
            }
            else if(wakeReason & (1<<XS1_UIFM_PHY_CONTROL_RESUMESE0))
            {
                /* Unsuspend phy */        
                write_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_PHY_CONTROL_REG, 0); 
                
                /* Wait for usb clock */
                p_usb_clk when pinseq(1) :> int _;
                p_usb_clk when pinseq(0) :> int _;
                p_usb_clk when pinseq(1) :> int _;
                p_usb_clk when pinseq(0) :> int _;  

                /* Set IFM to decoding linestate.. IFM regs reset when phy suspended */ 
                write_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_IFM_CONTROL_REG, 
                    (1<<XS1_UIFM_IFM_CONTROL_DECODELINESTATE)
                    | (1<< XS1_UIFM_IFM_CONTROL_SOFISTOKEN));
                
                write_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_DEVICE_ADDRESS_REG, 0);

                XUD_UIFM_PwrSigFlags();

                {
                    unsigned time;
                    t :> time;
                    t when timerafter(time+250000) :> void;
                }
                return 1;
            }
        }


#endif
    


    {
        unsigned rdata = 0;

        /* TODO Wait for suspend (j) to come through filter */
        while(1)
        {
            unsigned  x;
            read_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_PHY_TESTSTATUS_REG, x);
            x >>= 9;
            x &= 0x3;
            if(x == 1)
            {
                break;
            }
        }
    
        while(1)
        {
            read_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_PHY_TESTSTATUS_REG, rdata);
            rdata >>= 9;
            rdata &= 0x3; 
            
            if(rdata == 2)
            {
                /* Resume */
                
                /* Un-suspend phy */ 
                write_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_PHY_CONTROL_REG, 0);

                /* TODO WAIT FOR CLK */
                if(g_curSpeed == XUD_SPEED_HS)
                        {
                            
                            /* Back to high-speed */
                            write_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_FUNC_CONTROL_REG, 0);
                        }              
                /* Wait for end of resume */
                while(1)
                {
                    read_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_PHY_TESTSTATUS_REG, rdata);
                    rdata >>= 9;
                    rdata &= 0x3; 

                    /* SE0 */            
                    if(rdata == 0)
                    {
                        
                        return 0;
                    }
                    else if(rdata == 1)
                    {
                        break;
                    }
                }
            }
            else if(rdata == 0)
            {
                /* Reset */
                //while(1)
                {
                    //int count = 0;
                    //read_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_PHY_TESTSTATUS_REG, rdata);
                    //rdata >>= 9;
                    //rdata &= 0x3;
                    
                    //if(rdata != 0)
                    //{
                        /* Se0 gone away...*/  
                      //  break; 
                    //}
                    //else
                    //{
                      //  count++;
                        //if(count>0)
                       // {
                        /* Un-suspend phy */
                        write_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_PHY_CONTROL_REG, 0);
                        return 1;
                        //}
                  //  }

                }
            }
        }
    }



#else


    
    while(1)
    {
        /* Read flags reg... */
    
#ifdef ARCH_S
        read_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_IFM_FLAGS_REG, tmp);
#else
        tmp = XUD_UIFM_RegRead(reg_write_port, reg_read_port, UIFM_REG_FLAGS);
#endif
        if(tmp & UIFM_FLAGS_SE0)
        {
            //printint(1);
            t :> time;
            select
            {
                case flag2_port when pinseq(0) :> void:
                    //Se0 gone away, keep looping
                    break;

                case t when timerafter(time+250000) :> void:
                    return 1;

            }
        }

        /* Look for HS J / FS K */
        if (tmp & UIFM_FLAGS_FS_K)
        {
            /* Wait for end of resume (SE0) */
            while(1)
            {
#ifdef ARCH_S
                read_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_IFM_FLAGS_REG, tmp);
#else
                tmp = XUD_UIFM_RegRead(reg_write_port, reg_read_port, UIFM_REG_FLAGS);
#endif
            
                if(tmp & UIFM_FLAGS_FS_J)
                {
                   break;
                }
                else if(tmp & UIFM_FLAGS_SE0)
                {
                    /* Resume detected from suspend: switch back to HS (suspendm high) and continue...*/                              
                    if(g_curSpeed == XUD_SPEED_HS)
                    {
#ifdef ARCH_S
                        write_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_FUNC_CONTROL_REG, 0);
#else
                        XUD_UIFM_RegWrite(reg_write_port, UIFM_REG_PHYCON, 0x1);
#endif
                    }
                    
                    while(1)
                    {
#ifdef ARCH_S
                        read_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_IFM_FLAGS_REG, tmp);
#else
                        tmp = XUD_UIFM_RegRead(reg_write_port, reg_read_port, UIFM_REG_FLAGS);
#endif
                    
                        if(!(tmp & UIFM_FLAGS_SE0))
                        {
                            return 0;
                        }
                    }
                }
            }

            return 0;
        }
    }
#endif

    return 0;
}


#if 0
/** XUD_DoSuspend
  * @brief  Function called when device is suspended. This should include any clock down code etc.
  * @return True if reset detected during resume */
int XUD_Suspend()
{
    int tmp;
    int reset = 1;
    timer t;
    unsigned time;
    int tmp2;
    int ok = 1;

    /* Whilst in suspend there is a FS J (HS K) state on bus , we should look for FS K
     (resume) or SE0 (reset) */
    
    /* TODO currently we poll flags reg here, but to save power lets setup the flag ports and use events...*/

    /* Clear flags reg just to make sure... */
    //XUD_UIFM_RegWrite(reg_write_port, UIFM_REG_FLAGS, 0);  // TODO: should read and only update correct bit 
    
            //flag2_port when pinseq(0) :> tmp2;
    while(1)
    {
        /* Read flags reg... */
        tmp = XUD_UIFM_RegRead(reg_write_port, reg_read_port, UIFM_REG_FLAGS);

        if(tmp & UIFM_FLAGS_SE0)
            return 1;

        if(tmp & UIFM_FLAGS_FS_K)
        { 
            printstr("resume\n");

                    XUD_UIFM_RegWrite(reg_write_port, UIFM_REG_PHYCON, 0x1);

            return 0;
       }
     
     }
}
      
       // select
        {
         //   case flag2_port when pinseq(1) :> tmp2:
               
               //XUD_Sup_Delay(200000);
                
                //t :> time;

                  //      t :> susresettime;
               // ok = 1;
                //while(ok)
               // {
                    //select
                    //{
                    //case flag2_port when pinseq(0) :> void:
                        //Se0 gone away, keep looping
                      //  break;

                        //case t when timerafter(time+2500) :> void: //2.5 us T_FILTSE0
                        //XUD_Sup_Delay(600000);
                        //printstr("R IN S\n");
                        
                          //  tmp = XUD_UIFM_RegRead(reg_write_port, reg_read_port, UIFM_REG_FLAGS);
                            //printhexln(tmp);
                       //     //XUD_Sup_Delay(2500);
                    //        XUD_Sup_Delay(5000000);
                        //printstr("R IN S\n");
                           // return 1;

                      //  default:
                        //    tmp = XUD_UIFM_RegRead(reg_write_port, reg_read_port, UIFM_REG_FLAGS);
                          //  if(!(tmp&0x20))
                            //    ok = 0;

                        //printstr("R IN S\n");
                              //  break;
                            

                 //   }

                //}
               // break;


        /* Look resume (for HS J / FS K) */
        case flag1_port when pinseq(1) :> tmp2:
        if (tmp2)
        {

            /* Wait for USB clock */
            p_usb_clk when pinseq(1) :> int _;
            p_usb_clk when pinseq(0) :> int _;
            p_usb_clk when pinseq(1) :> int _;
            p_usb_clk when pinseq(0) :> int _;


                    XUD_UIFM_RegWrite(reg_write_port, UIFM_REG_PHYCON, 0x1);

            return 0;

            /* Wait for end of resume (SE0) */
            while(1)
            {
                tmp = XUD_UIFM_RegRead(reg_write_port, reg_read_port, UIFM_REG_FLAGS);
            
                if(tmp & UIFM_FLAGS_SE0)
                {
                    /* Resume detected from suspend: switch back to HS (suspendm high) and continue...*/                inSus = 0;
                    XUD_UIFM_RegWrite(reg_write_port, UIFM_REG_PHYCON, 0x1);

                    while(1)
                    {
                        tmp = XUD_UIFM_RegRead(reg_write_port, reg_read_port, UIFM_REG_FLAGS);
                    
                        if(!(tmp & UIFM_FLAGS_SE0))
                        {
                            //printstr("RESUMEEND\n"); 
                            return 0;
                        }
                    }
                }
            }

        }
        break;
        }

    }

    return reset;
}

#endif
#if 0
    {
        timer t;
        unsigned time;
        unsigned rdata1 = 0;
        unsigned rdata2 = 0;
        unsigned rdata3 = 0;

        while(1)
        {
            read_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_PWR_ID, XS1_GLX_PWR_SEQUENCE_DBG_ADRS, rdata1);
        
            rdata1>>=16;
            rdata1&=0x7;

            if(rdata1 != 1)
                break;

            read_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_PHY_TESTSTATUS_REG, rdata2);
            rdata2 >>= 9;
            rdata2 &= 0x3;
            if(rdata2 == 2)
            {
               // if(rdata2 != 3)
                    break;
            }

            //read_glx_periph_word(get_tile_id(USB_TILE_REF), XS1_GLX_PERIPH_USB_ID, XS1_UIFM_PHY_CONTROL_REG, rdata3);
            //rdata3 >>= 12;
            //rdata3 &= 0x3;
            
            //if(rdata3!=0)
              //  break; 
 

        }
        
        //before>>12;
        //before&=3;
        printhexln(rdata1);
        printhexln(rdata2);

    }
#endif 

