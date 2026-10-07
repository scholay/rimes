# macOS 27：特定应用切换输入法时闪退

[#90](https://github.com/scholay/rimes/issues/90) 的报告者在 macOS 27.0（26A428）的 App Store 沙盒版微信 4.1.5、QQ 6.9.93 中，遇到切换到 RIMES 1.1.0 时宿主应用闪退。报告者提供了 `CFRelease(NULL)` 调用栈，并通过自己的沙盒测试进程将问题定位到应用持有的旧输入源缓存。维护者尚未独立复现这条崩溃路径；这是恢复建议，不是已完成的系统修复。运行中应用何时重建缓存也没有得到维护者验证。

安装器会注册、启用并核验 RIMES 输入源，但不会清理其他应用的缓存。重启应用、退出登录或注册成功，都不能保证解决本报告的情况。

## 仅处理一个已经出现问题的应用

1. 先切回苹果输入法或其他正常输入法，保存未发送的文字，并完全退出受影响的应用。
2. 在该 Mac 当前图形登录用户的普通终端中操作，不使用 `sudo`、root 或另一个用户的会话。下面只读检查中，`id -u` 与 `/dev/console` 的所有者必须相同，且不能为 `0`：

   ```bash
   id -u
   stat -f '%u' /dev/console
   getconf DARWIN_USER_CACHE_DIR
   ```

3. `getconf` 输出的是当前用户的缓存根目录。在 Finder 的「前往文件夹」中打开它，仅进入受影响应用的一个目录：微信为 `com.tencent.xinWeChat`，QQ 为 `com.tencent.qq`。不要处理其他应用或整个缓存根目录。
4. 在该目录中仅检查这两个精确文件名：

   ```text
   com.apple.IntlDataCache.le
   com.apple.IntlDataCache.le.kbdx
   ```

   两个文件及其所在应用目录都必须属于当前用户；两个文件必须都存在且为普通文件，不能是符号链接、文件夹或其他类型。任何一项不符合，或操作报错，就停下并在 #90 提供脱敏情况，不要改权限或扩大清理范围。可用 `ls -ldn` 查看该目录和两个文件的类型及数字所有者，与 `id -u` 核对；类型开头应分别为 `d` 和 `-`，不能为 `l`。
5. 在该用户的本地目录中创建一个新的空备份文件夹，把这两个文件**移动到备份目录**，保留原文件名，并记录它们原来的完整路径。不删除文件，不使用通配符、递归清理、批量扫描或任何「删除所有不含 RIMES 的缓存」命令。若第一个已移动、第二个失败，先停止；已移动的文件仍保留在备份目录中。
6. 再启动该应用，确认未发送内容仍在，然后试一次切换到 RIMES。报告者称其应用会重建缓存并恢复切换；维护者不保证每个应用或系统版本都会如此。若仍闪退，停止反复切换，继续使用其他输入法，并提供脱敏崩溃栈、macOS、应用版本及是否为 App Store 沙盒版。

如需回退，先完全退出同一个应用，把新生成的这两个同名文件另外备份，再将原备份放回记录的原路径；不要覆盖或删除无关文件。保留备份直到确认该应用工作正常。此流程不修改 `~/Library/RIMES`、方案、用户词库、应用文档或账号数据。

## English

The reporter of [#90](https://github.com/scholay/rimes/issues/90) observed host-app crashes when switching to RIMES 1.1.0 in App Store sandboxed WeChat 4.1.5 and QQ 6.9.93 on macOS 27.0 (26A428). Their crash stack includes `CFRelease(NULL)`, and their own sandbox probe points to stale per-app input-source caches. The maintainer has not independently reproduced that crash path or verified when running apps rebuild these caches. This is a recovery suggestion, not a completed system fix. Successful input-source registration, restarting an app, or logging out does not guarantee recovery.

For one affected app only:

1. Select another working input method, save unsent text, and completely quit the affected app.
2. Use the currently logged-in GUI user's normal terminal, without `sudo` or root. Run the three read-only commands above: the UID from `id -u` must match the owner of `/dev/console` and must not be `0`. Stop if it does not.
3. Open the directory returned by `getconf DARWIN_USER_CACHE_DIR` in Finder, then only `com.tencent.xinWeChat` for WeChat or `com.tencent.qq` for QQ.
4. Check the exact two filenames above. The app directory must be a real directory, not a symbolic link; both files must exist and be regular files, not symbolic links or directories. The directory and both files must belong to the current user. Use `ls -ldn` to compare their numeric owners with `id -u`. Stop on missing files, unexpected types/owners, or errors; do not change permissions or expand the scope.
5. Move only those two files to a new empty local backup folder, keeping their names and recording the original paths. Do not delete them, use wildcards, scan other apps, or clear the whole cache. If a move fails, stop and retain whatever has already been backed up.
6. Start that app and try switching once. The reporter says rebuilding its cache restored switching. If the crash persists, use another input method and share a redacted crash stack plus OS/app versions in #90.

To revert, quit the same app, separately back up any newly generated files with these exact names, and return the original backups to their recorded paths. Keep the backups until acceptance. No step changes RIMES schemes/user dictionaries, app documents, or account data.
