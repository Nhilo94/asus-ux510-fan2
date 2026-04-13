# nbfc-linux Config for ASUS UX510UWK

## Fan 1 (CPU) — via nbfc

The file `Asus Zenbook UX510UWK.json` controls the CPU fan via EC register `0x97` (decimal 151).

To use:
```bash
sudo cp "Asus Zenbook UX510UWK.json" /usr/share/nbfc/configs/
sudo nbfc config -s "Asus Zenbook UX510UWK"
sudo nbfc start
```

## Fan 2 (GPU) — requires asus-fan2-ctrl

The GPU fan uses extended EC register `0xF922` which is beyond nbfc's standard EC range.
Install `asus-fan2-ctrl` from the parent directory for fan 2 support.

## Submitting to nbfc-linux

Copy `Asus Zenbook UX510UWK.json` to your nbfc-linux fork:
```bash
cp "Asus Zenbook UX510UWK.json" /path/to/nbfc-linux/share/nbfc/configs/
```
Then submit a PR to https://github.com/nbfc-linux/nbfc-linux
