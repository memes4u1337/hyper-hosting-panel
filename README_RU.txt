OLD ZOMBIE REAL FASTDL R9

Exact root cause found in the supplied build:
addons/amxmodx/configs/plugins.ini enables oldz_safe_download_r8.amxx first.
Its source clears sv_downloadurl during precache/config/init and every second forever.

That makes the CS client fall back to the slow game-server download channel even though nginx itself is fast.

Additional fixes:
- copies m82*.wav from the build payload into sound/weapons/
- adds Ghost_Count/combo sounds to precache/resource delivery
- disables broken amx_time_voice *_period composition
- normalizes all FastDL cfg files
- tries to restore 384-byte HTML files masquerading as MDL/SPR from Steam base
- fixes zm_2day.res fire2.spr path
- checks actual engine process/build and, if still BUILD 4419, runs Runtime Manager 'recommended' migration only
