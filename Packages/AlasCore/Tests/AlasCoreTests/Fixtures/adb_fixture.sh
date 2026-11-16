#!/bin/sh
case "$*" in
  "devices -l") printf 'List of devices attached\nemulator-5554 device model:sdk_gphone64_arm64\n' ;;
  *"emu avd name") printf 'Medium_Phone\r\nOK\r\n' ;;
  *) echo 16 ;;
esac
