# Sway rules for launchers (Heroic/Lutris manager): stable focus, dialogs
# floating at natural size (installer dialogs, language pickers) instead of
# being stretched fullscreen, plus keybindings to arrange windows over
# Moonlight (Alt+Tab is captured by the local client's DE, so we use Super).
mkdir -p "$HOME/.config/sway"
cat > "$HOME/.config/sway/custom-cfg" <<'SWAY'
focus_follows_mouse no
for_window [shell="xwayland"]      floating enable, move position center
for_window [window_type="dialog"]  floating enable, move position center
for_window [window_type="utility"] floating enable, move position center
for_window [window_role="dialog"]  floating enable, move position center
# empty main GOG-installer window ("Instalator"/"Setup") - smaller, top-left
for_window [title="^(Instalator|Setup)$"] floating enable, resize set 1000 700, move position 20 40

# manual window control over Moonlight (Super, not Alt - avoids client DE clash):
set $mod Mod4
bindsym $mod+Tab   focus next
bindsym $mod+grave focus next
bindsym $mod+f     fullscreen toggle
bindsym $mod+c     move position center
bindsym $mod+space floating toggle
SWAY
echo "[sway-tweaks] custom-cfg written"
