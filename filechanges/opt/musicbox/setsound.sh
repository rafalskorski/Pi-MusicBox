#!/bin/bash
#
# MusicBox Sound configuration script
#

CONFIG_FILE=/boot/config/settings.ini

# Define LSB log_* functions.
. /lib/lsb/init-functions

log_use_fancy_output

log_begin_msg "Setting sound configuration..."
rm -f /etc/asound.conf

I2S_CARD=
USB_CARD=
INT_CARD=
HDMI_CARD=

function enumerate_alsa_cards()
{
    i2s_output=$(echo $OUTPUT | tr -cd "[:alnum:]")
    while read -r line
    do
        ## Dac
        #card 0: sndrpihifiberry [snd_rpi_hifiberry_dac], device 0: HifiBerry DAC HiFi pcm5102a-hifi-0 []
        ## Digi
        #card 2: sndrpihifiber_1 [snd_rpi_hifiberry_digi], device 0: HifiBerry Digi HiFi wm8804-spdif-0 []
        ## Dac+
        #card 1: sndrpihifiber_1 [snd_rpi_hifiberry_dacplus], device 0: HiFiBerry DAC+ HiFi pcm512x-hifi-0 []
        #IQaudIO
        #card 1: sndrpiiqaudioda [snd_rpi_iqaudio_dac], device 0: IQaudIO DAC HiFi pcm512x-hifi-0 []
        #card 1: IQaudIODAC [IQaudIODAC], device 0: IQaudIO DAC HiFi pcm512x-hifi-0 []
        ## Wolfson
        #Card 0: sndrpiwsp [snd_rpi_wsp], device 0: WM5102 AiFi wm5102-aif1-0 []
        ## Onboard
        #card 0: ALSA [bcm2835 ALSA], device 0: bcm2835 ALSA [bcm2835 ALSA]
        #card 0: ALSA [bcm2835 ALSA], device 1: bcm2835 ALSA [bcm2835 IEC958/HDMI]
        ## USB
        #card 2: AUDIO [USB  AUDIO], device 0: USB Audio [USB Audio]
        #card 2: DAC [USB Audio DAC], device 0: USB Audio [USB Audio]
        #card 2: CODEC [USB Audio CODEC], device 0: USB Audio [USB Audio]

        # Replace unwanted '[]:,' characters.
        dev=($(echo $line | tr -d "[\[\]:,]"))
        card_num=${dev[1]}
        name=$(echo ${dev[3]} | tr -cd "[:alnum:]" | tr "[:upper:]" "[:lower:]")
        if [[ $name == "bcm2835"* ]]; then
            INT_CARD=$card_num
            log_progress_msg "Found internal device: card$INT_CARD $name"
            if tvservice -s | grep -q HDMI; then
                echo "HDMI output connected"
                HDMI_CARD=$card_num
            fi
        elif [[ $name == *"$i2s_output" ]]; then
            I2S_CARD=$card_num
            log_progress_msg "Found i2s device: card$I2S_CARD $name"
        elif [[ $line =~ "usb audio" ]]; then
            USB_CARD=$card_num
            log_progress_msg "Found usb device: card$USB_CARD $name"
        else
            log_progress_msg "Found unknown device: card$card_num $name"
        fi
    done < <(aplay -l | grep card)
}

if [[ $INI_READ != true ]] 
then
    echo "read ini"
    # Import ini parser
    . /opt/musicbox/read_ini.sh

    # Convert windows ini to unix
    dos2unix -n $CONFIG_FILE /tmp/settings.ini > /dev/null 2>&1 || true

    # ini vars to mopidy settings
    read_ini /tmp/settings.ini

    rm /tmp/settings.ini > /dev/null 2>&1 || true
fi

# If output not defined, it will automatically detect USB / HDMI / Analog in given order
# It is at this moment not possible to detect whether an i2s device is connected hence
# i2s is only selected if explicitly given as output in the config file
OUTPUT=$(echo $INI__musicbox__output | tr "[:upper:]" "[:lower:]")
CARD=

if [[ -z "$OUTPUT" ]]
then
    OUTPUT="auto"
fi

# Get alsa cards
enumerate_alsa_cards

case $OUTPUT in
    analog)
        CARD=$INT_CARD
        ;;
    hdmi)
        CARD=$HDMI_CARD
        ;;
    usb)
        CARD=$USB_CARD
        ;;
    hifiberry_dac)
        modprobe snd_soc_pcm5102a
        modprobe snd_soc_hifiberry_dac
        enumerate_alsa_cards
        CARD=$I2S_CARD
        ;;
    hifiberry_digi)
        modprobe snd_soc_wm8804
        modprobe snd_soc_hifiberry_digi
        enumerate_alsa_cards
        CARD=$I2S_CARD
        ;;
    hifiberry_dacplus)
        modprobe snd_soc_hifiberry_dacplus
        enumerate_alsa_cards
        CARD=$I2S_CARD
        ;;
    iqaudio_dac)
        modprobe snd_soc_pcm512x
        modprobe snd_soc_iqaudio_dac
        enumerate_alsa_cards
        CARD=$I2S_CARD
        ;;
    wolfson)
        OUTPUT=wsp
        enumerate_alsa_cards
        CARD=$I2S_CARD
        ;;
esac

echo "Card $CARD i2s $I2S_CARD output $OUTPUT usb $USB_CARD intc $INT_CARD"

# If preferred output not found or given fall back to auto detection
if [[ -z $CARD ]];
then
echo "autod"
    if [[ -n $USB_CARD ]]; then
        CARD=$USB_CARD
        OUTPUT="usb"
    else
        CARD=$INT_CARD
        if  [[ -n $HDMI_CARD ]]; then
            OUTPUT="hdmi"
        else
            OUTPUT="analog"
        fi
    fi
fi

echo "Card $CARD i2s $I2S_CARD output $OUTPUT usb $USB_CARD intc $INT_CARD"

if [[ -z $CARD ]];
then
    echo "ERROR - NO CARD FOUND"
    exit 1
fi

log_progress_msg "Line out set to $OUTPUT card $CARD"

if [ "$OUTPUT" == "usb" -a "$INI__musicbox__downsample_usb" == "1" ]
# resamples to 44K because of problems with some usb-dacs on 48k (probably related to usb drawbacks of Pi)
# and extra buffer for usb
#if [ "$OUTPUT" == "usb" ]
then
cat << EOF > /etc/asound.conf
pcm.!default {
    type plug
    slave.pcm {
        type dmix
        ipc_key 1024
        slave {
            pcm "hw:$CARD"
            rate 44100
#            period_time 0
#            period_size 4096
#            buffer_size 131072
        }
    }
}
ctl.!default {
    type hw
    card $CARD
}
EOF
else
cat << EOF > /etc/asound.conf
pcm.!default {
    type hw
    card $CARD
}
ctl.!default {
    type hw
    card $CARD
}
EOF
fi

# Reset mixer
amixer cset numid=3 0 > /dev/null 2>&1 || true

if [ "$OUTPUT" == "analog" ]
then
    # Set mixer to analog output
    amixer cset numid=3 1 > /dev/null 2>&1 || true
elif [ "$OUTPUT" == "hdmi" ]
then
    # Set mixer to hdmi
    amixer cset numid=3 2 > /dev/null 2>&1 || true
fi

for CTL in \
        Master \
        PCM \
        Line \
        "PCM,1" \
        Wave \
        Music \
        AC97 \
        "Master Digital" \
        DAC \
        "DAC,0" \
        "DAC,1" \
        Speaker \
    Playback \
    Digital \
    Aux \
    Front \
    Center
do
    # Set initial hardware volume
    amixer set -c $CARD "$CTL" 96% unmute > /dev/null 2>&1 || true 
    #amixer set -c $CARD "$CTL" ${VOLUME}% unmute > /dev/null 2>&1 || true 
done

# Set PCM of Pi higher, because it's really quiet otherwise (hardware thing)
amixer -c 0 set PCM playback 98% > /dev/null 2>&1 || true &
#amixer -c 0 set PCM playback ${VOLUME}% > /dev/null 2>&1 || true &
