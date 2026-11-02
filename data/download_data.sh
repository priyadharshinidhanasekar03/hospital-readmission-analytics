#!/usr/bin/env bash
# Downloads the UCI "Diabetes 130-US hospitals for years 1999-2008" dataset.
# License: CC BY 4.0  -  https://archive.ics.uci.edu/dataset/296
set -euo pipefail
cd "$(dirname "$0")"
curl -L -o dataset.zip \
  "https://archive.ics.uci.edu/static/public/296/diabetes+130-us+hospitals+for+years+1999-2008.zip"
unzip -o dataset.zip
rm dataset.zip
echo "Saved diabetic_data.csv and IDS_mapping.csv"
