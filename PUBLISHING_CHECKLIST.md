# Publishing Checklist

## 1. Content Review

- [x] review `README.md`
- [x] review `docs/OPERATIONAL_GUIDE.md`
- [x] verify that the script is the intended version
- [x] remove any unnecessary local files

## 2. License Decision

- [x] MIT License added (see [LICENSE](./LICENSE))

## 3. Minimum Technical Checks

Run:

```bash
bash -n veeam_hardened_repository_safe.sh
bash -n tests/security_regression_tests.sh
bash -n tests/veeam_test_runner.sh
shellcheck --severity=style \
  veeam_hardened_repository_safe.sh \
  tests/security_regression_tests.sh \
  tests/veeam_test_runner.sh \
  tests/full_flow_in_docker.sh
bash tests/security_regression_tests.sh
bash veeam_hardened_repository_safe.sh --help
bash veeam_hardened_repository_safe.sh --help-full
```

Run the root/LVM integration suite on Ubuntu 22.04 and 24.04 through CI before
tagging a release.

## 4. Create the GitHub Repository

Example:

```bash
git init
git add .
git commit -m "Initial release"
git branch -M main
git remote add origin https://github.com/OS3RVNO/veeam-hardened-repository.git
git push -u origin main
```

## 5. Suggested Repository Description

Suggested short description:

`Safer Bash bootstrap for Veeam Hardened Repository on Ubuntu 22.04/24.04, with prepare and post-attach-lockdown phases.`

## 6. Suggested GitHub Topics

- `veeam`
- `backup`
- `ubuntu`
- `bash`
- `linux`
- `hardening`
- `xfs`
- `lvm`
