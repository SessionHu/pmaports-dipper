#!/usr/bin/env python3
# Copyright 2020 Oliver Smith
# SPDX-License-Identifier: GPL-3.0-or-later

import glob
import tempfile
import sys
import subprocess

# Same dir
import common

# pmbootstrap
import testcases.add_pmbootstrap_to_import_path  # noqa
import pmb.parse
import pmb.parse.version
import pmb.helpers.logging


ERR_PKGREL_NONZERO = 1
ERR_PKGVER_NOT_INCREMENTED = 2

def get_package_version(args, package, revision, check=True):
    # Redirect stderr to /dev/null, so git doesn't complain about files not
    # existing in master for new packages
    stderr = None
    if not check:
        stderr = subprocess.DEVNULL

    # Run something like "git show upstream/master:main/hello-world/APKBUILD"
    pmaports_dir = common.get_pmaports_dir()
    pattern = pmaports_dir + "/**/" + package + "/APKBUILD"
    path = glob.glob(pattern, recursive=True)[0][len(pmaports_dir + "/"):]
    apkbuild_content = common.run_git(["show", revision + ":" + path], check,
                                      stderr)
    if not apkbuild_content:
        return None

    # Save APKBUILD to a temporary path and parse it from there. (Not the best
    # way to do things, but good enough for this CI script.)
    with tempfile.TemporaryDirectory() as tempdir:
        with open(tempdir + "/APKBUILD", "w", encoding="utf-8") as handle:
            handle.write(apkbuild_content)
        parsed = pmb.parse.apkbuild(args, tempdir + "/APKBUILD", False, False)

    return parsed["pkgver"] + "-r" + parsed["pkgrel"]


def version_compare_operator(result):
    """ :param result: return value from pmb.parse.version.compare() """
    if result == -1:
        return "<"
    elif result == 0:
        return "=="
    elif result == 1:
        return ">"

    raise RuntimeError("Unexpected version_compare_operator input: " + result)


def print_error(error):
    if error == ERR_PKGREL_NONZERO:
        print('''
        ERROR: pkgrel MUST be 0 for all new aports, you can fix this
        by updating your apkbuild and using git commit --amend followed
        by a force push.
        ''')
    elif error == ERR_PKGVER_NOT_INCREMENTED:
        print('''
        ERROR: You must increase the pkgver for updated packages, fix this
        and then force push. You may need to rebase on master first.
        (see https://postmarketos.org/rebase)

        If your change doesn't require rebuilding the packages (e.g. only the
        arch= line was changed) then add '[ci:skip-vercheck]' to the latest
        commit with git commit --amend.
        ''')
    
    exit(1)


def check_versions(args, packages):
    error = 0

    # Get relevant commits: compare HEAD against upstream/master or HEAD~1
    # (the latter if this CI check is running on upstream/master). Note that
    # for the common.get_changed_files() code, we don't check against
    # upstream/master, but against the latest common ancestor. This is not
    # desired here, since we already know what packages changed, and really
    # want to check if the version was increased towards *current* master.
    commit = "upstream/master"
    if common.run_git(["rev-parse", "HEAD"]) == common.run_git(["rev-parse",
                                                                commit]):
        print("NOTE: upstream/master is on same commit as HEAD, comparing"
              " HEAD against HEAD~1.")
        commit = "HEAD~1"

    for package in packages:
        # Get versions, skip new packages
        head = get_package_version(args, package, "HEAD")
        master = get_package_version(args, package, commit, False)
        if not master:
            if head.rpartition('r')[2] != "0":
                print(f"- {package}: {head} (HEAD) (new package) [ERROR]")
                error = ERR_PKGREL_NONZERO
            else:
                print(f"- {package}: {head} (HEAD) (new package)")
            continue

        # Compare head and master versions
        result = pmb.parse.version.compare(head, master)
        if result != 1:
            error = ERR_PKGVER_NOT_INCREMENTED

        # Print result line ("- hello-world: 1-r2 (HEAD) > 1-r1 (HEAD~1)")
        formatstr = "- {}: {} (HEAD) {} {} ({})"
        if result != 1:
            formatstr += " [ERROR]"
        operator = version_compare_operator(result)
        print(formatstr.format(package, head, operator, master, commit))

    if error:
        exit_with_error_message(error)


if __name__ == "__main__":
    # Get and print modified packages
    common.add_upstream_git_remote()
    packages = common.get_changed_packages()
    print(f"Changed packages: {packages}")

    # Verify modified package count
    common.get_changed_packages_sanity_check(len(packages))
    if len(packages) == 0:
        print("no aports changed in this branch")
        exit(0)

    # Potentially skip this check
    if common.commit_message_has_string("[ci:skip-vercheck]"):
        print("WARNING: not checking for changed package versions"
              " ([ci:skip-vercheck])!")
        exit(0)

    # Initialize args (so we can use pmbootstrap's APKBUILD parsing)
    sys.argv = ["pmbootstrap.py", "chroot"]
    args = pmb.parse.arguments()
    pmb.helpers.logging.init(args)

    # Verify package versions
    print("checking changed package versions...")
    check_versions(args, packages)
