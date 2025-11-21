1. Verzeichnis wechseln
```bash
cd ~/devel
```

2. alte Datei verschieben
```bash
mv vc4-kms-dsi-lt070me05000-overlay.dts vc4-kms-dsi-lt070me05000-overlay.dts~ 2>/dev/null
```

3. aktuelles Overlay holen
```bash
wget https://raw.githubusercontent.com/CoHoB/cm4_lcd/refs/heads/main/overlay/vc4-kms-dsi-lt070me05000-overlay.dts
```

4. Overlay übersetzen
```bash
sudo dtc -@ -I dts -O dtb -o vc4-kms-dsi-lt070me05000.dtbo vc4-kms-dsi-lt070me05000-overlay.dts
```

5. Overlay installieren
```bash
sudo cp vc4-kms-dsi-lt070me05000.dtbo /boot/overlays/
```
