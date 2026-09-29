# Rejouer les mesures

`run.py` mesure des répertoires **déjà montés** sous Linux. Il nécessite Python 3 et `fio` 3.x. Il crée uniquement des répertoires temporaires dans chaque point de montage, puis y fait un contrôle SHA-256, un contrôle `flock` entre processus locaux et cinq profils `fio`. Les erreurs, y compris `ESTALE`, sont écrites dans le JSON même si un cas échoue. Ne jamais lancer ce banc sur des données de production.

```sh
python3 benchmarks/validation/run.py --self-test
python3 benchmarks/validation/run.py \
  --case virtiofs=/mnt/filestorage \
  --case loop-ext4=/mnt/loop-validation \
  --size 256M --runtime 20 --direct 1 --out validation-results
```

Profils : écriture et lecture séquentielles 1 MiB, lecture et écriture aléatoires 4 KiB pendant 20 s, puis écriture aléatoire 4 KiB avec `fdatasync` après chaque écriture. Un seul job, profondeur 1, `ioengine=sync`, `O_DIRECT=1`. Le JSON contient IOPS, MiB/s, p50/p95/p99 de latence, latence de `fdatasync` quand disponible, code de sortie et sortie brute `fio`. Pour l'image loopback, vérifier que `losetup --list --output NAME,BACK-FILE,DIO` affiche `DIO=1` ; un résultat obtenu avec `DIO=0` peut mesurer le cache de la passerelle plutôt que File Storage.

Pour tester une publication depuis un disque local :

```sh
python3 benchmarks/validation/run.py \
  --publish-local /mnt/local-stage --publish-to /mnt/filestorage \
  --publish-size-mib 512 --out validation-results
```

La publication écrit des blocs aléatoires, fait `fsync`, copie vers un nom temporaire, refait `fsync`, renomme et compare les SHA-256. Le fichier publié reste sur la destination ; la source locale reste en place en cas d'échec de contrôle. Le débit d'un petit fichier encore en cache ne doit pas être interprété comme un débit soutenu.

`--case`, `--publish-to` et `--watch` exigent un point de montage pour éviter d'écrire sur le disque système lorsqu'un montage manque. `--allow-non-mount` lève explicitement cette garde pour un essai local volontaire. `--peer` et `--peer-path` permettent un contrôle `flock` inter-hôtes via SSH sans mot de passe. `--watch MONTAGE --watch-seconds 180` enregistre des contrôles répétés pendant une interruption déclenchée séparément ; il ne provoque pas l'interruption.

Le protocole précis et les résultats du 29 septembre 2026 sont dans [le rapport](../../docs/validation-2026-09-29.md).
