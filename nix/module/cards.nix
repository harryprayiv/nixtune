# The HiFiBerry cards, by product. Data, not a module: hardware.nix imports
# this file and nothing else does.
#
# For each card:
#
#   products  the boards it covers, for the option description
#   overlay   the device tree overlay the Raspberry Pi kernel ships for it
#   params    overlay parameters written into config.txt with it, as a set
#             of booleans
#   mixer     the ALSA simple control that sets the level, or null when the
#             card has none and MPD's software mixer sets it
#   convert   whether MPD may convert the format: false where the chip takes
#             every rate a library has, true where it does not
#   pi5Only   the overlay runs only on a Raspberry Pi 5
#
# Every card registers as ALSA card id sndrpihifiberry. The machine drivers
# name their cards snd_rpi_hifiberry_<card> (sound/soc/bcm/hifiberry_*.c,
# rpi-simple-soundcard.c, rpi-wm8804-soundcard.c), and ALSA makes the id from
# the last space-separated word of the name, which here is the whole name,
# with everything but letters and digits removed and cut to 15 characters
# (sound/core/init.c, copy_valid_id_string). That is sndrpihifiberry for all
# of them.
#
# Where the facts come from: the overlays, their README and the codec drivers
# in the Raspberry Pi kernel, branch rpi-6.18.y.
#
#   pcm512x (DAC+, DAC2 Pro, the ADC boards, Amp2, Amp4, Amp100) and the
#   TAS5756 on the Amp4 Pro, which the same driver handles: "Digital
#   Playback Volume", capped at 0 dB by the machine driver unless the
#   overlay's 24db_digital_gain is set.
#   pcm1792a on the DAC2 HD (pcm179x.c): "DAC Playback Volume". The only card
#   here that has played through nixtune.
#   tas5713 on the Amp+: a control named "Master". It takes 8 to 48 kHz.
#   ma120x0p on the Amp3: "A.Mstr Vol Volume". It takes 44.1 to 192 kHz and
#   only 24- and 32-bit samples, so a 16-bit file needs converting.
#   wm8804 on the Digi boards takes 32 to 192 kHz in 16, 20 or 24 bits;
#   pcm512x takes 8 to 384 kHz and pcm179x 10 to 200 kHz.
#   pcm5102a (DAC+ Light, DAC+ Zero, MiniAmp, Beocreate, DAC8x), wm8804 (the
#   Digi boards) and the DAC+ DSP's dummy codec: no volume control.
#
# The card table in hifiberry-nixos's README writes Amp100's overlay as
# hifiberry-amp100,automute. The overlay defines no parameter of that name;
# its parameter is auto_mute (hifiberry-amp100-overlay.dts, __overrides__),
# so it is auto_mute here.
#
# The Studio cards (Studio DAC8x, Studio DAC8x Pro, Studio Digi) are not in
# the table. Their driver names the card "Hifiberry Studio Soundcard", so
# they register as Soundcard, and they would need a card entry of their own.
# The ADC and ADC8x are input-only and are not outputs.
let
  card =
    {
      products,
      overlay,
      params ? { },
      mixer,
      convert ? false,
      pi5Only ? false,
    }:
    {
      inherit
        products
        overlay
        params
        mixer
        convert
        pi5Only
        ;
    };

  dacplusStd = card {
    products = "DAC+ (standard), Amp2, Amp4";
    overlay = "hifiberry-dacplus-std";
    mixer = "Digital";
  };

  dacplusPro = card {
    products = "DAC+ Pro, DAC2 Pro";
    overlay = "hifiberry-dacplus-pro";
    mixer = "Digital";
  };

  dacplusAdcPro = card {
    products = "DAC+ ADC Pro, DAC2 ADC Pro";
    overlay = "hifiberry-dacplusadcpro";
    mixer = "Digital";
  };

  dac = card {
    products = "DAC+ Light, DAC+ Zero, MiniAmp, Beocreate";
    overlay = "hifiberry-dac";
    mixer = null;
  };

  digiPro = card {
    products = "Digi+ Pro, Digi2 Pro";
    overlay = "hifiberry-digi-pro";
    mixer = null;
  };
in
{
  dac2hd = card {
    products = "DAC2 HD";
    overlay = "hifiberry-dacplushd";
    mixer = "DAC";
  };

  dacplus = dacplusStd;
  amp2 = dacplusStd;
  amp4 = dacplusStd;

  dacplus-pro = dacplusPro;
  dac2-pro = dacplusPro;

  dacplus-adc = card {
    products = "DAC+ ADC";
    overlay = "hifiberry-dacplusadc";
    mixer = "Digital";
  };

  dacplus-adc-pro = dacplusAdcPro;
  dac2-adc-pro = dacplusAdcPro;

  # The DSP sets the rate it runs at; which rates it accepts is not in the
  # kernel source.
  dacplus-dsp = card {
    products = "DAC+ DSP";
    overlay = "hifiberry-dacplusdsp";
    mixer = null;
    convert = true;
  };

  dac8x = card {
    products = "DAC8x";
    overlay = "hifiberry-dac8x";
    mixer = null;
    pi5Only = true;
  };

  dacplus-light = dac;
  dacplus-zero = dac;
  miniamp = dac;
  beocreate = dac;

  digi = card {
    products = "Digi, Digi+";
    overlay = "hifiberry-digi";
    mixer = null;
  };

  digi-pro = digiPro;
  digi2-pro = digiPro;

  amp = card {
    products = "Amp+";
    overlay = "hifiberry-amp";
    mixer = "Master";
    convert = true;
  };

  amp3 = card {
    products = "Amp3";
    overlay = "hifiberry-amp3";
    mixer = "A.Mstr Vol";
    convert = true;
  };

  amp4-pro = card {
    products = "Amp4 Pro";
    overlay = "hifiberry-amp4pro";
    mixer = "Digital";
  };

  amp100 = card {
    products = "Amp100";
    overlay = "hifiberry-amp100";
    params.auto_mute = true;
    mixer = "Digital";
  };
}
