#!/bin/bash

NEW_VERSION=`date -u +'%Y%m%d%H%M'`

PKGNAME=$1
if [ "x$PKGNAME" = "x" ]; then
    PKGNAME=raiderio-addon-${NEW_VERSION}.zip
fi

mkdir -p package

cd package

echo "Downloading latest zip to base off of..."
wget -O latest.zip https://wow.curseforge.com/projects/raiderio/files/latest

rm -rf addon
mkdir addon
find ../db -type d -name 'RaiderIO_DB_*' -exec cp -av {} addon \;
unzip -o -d addon latest.zip
find addon -name '*.xml' -exec rm -f {} \;
echo "Manual build $NEW_VERSION" > addon/CHANGES.txt

echo "Overlaying latest DB..."
cp -v ../db/db_*.lua addon/RaiderIO/db
cp ../*.{lua,toc,xml} addon/RaiderIO
cp ../locale/enUS.lua addon/RaiderIO/locale

echo "Setting up as version v$NEW_VERSION"
find . -name \*.toc -exec perl -pi -e "s/\@project-version\@/v$NEW_VERSION/" {} \;

cd addon
zip -r9 ../$PKGNAME RaiderIO*

ls -al ../$PKGNAME
