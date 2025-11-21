cd ~/devel
# alte Datei verschieben
mv vc4-kms-dsi-lt070me05000-overlay.dts vc4-kms-dsi-lt070me05000-overlay.dts~ 2>/dev/null

# aktuelles Overlay holen
wget https://raw.githubusercontent.com/CoHoB/cm4_lcd/refs/heads/main/overlay/vc4-kms-dsi-lt070me05000-overlay.dts

# Overlay übersetzen
sudo dtc -@ -I dts -O dtb -o vc4-kms-dsi-lt070me05000.dtbo vc4-kms-dsi-lt070me05000-overlay.dts

# Overlay installieren
sudo cp vc4-kms-dsi-lt070me05000.dtbo /boot/overlays/
