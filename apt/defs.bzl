"EXPERIMENTAL! Public API"

load("//apt/private:dpkg_status.bzl", _dpkg_status = "dpkg_status")
load("//apt/private:dpkg_statusd.bzl", _dpkg_statusd = "dpkg_statusd")
load("//apt/private:package_set.bzl", _AptPackageSetInfo = "AptPackageSetInfo", _apt_package_set = "apt_package_set")

dpkg_status = _dpkg_status
dpkg_statusd = _dpkg_statusd
AptPackageSetInfo = _AptPackageSetInfo
apt_package_set = _apt_package_set
