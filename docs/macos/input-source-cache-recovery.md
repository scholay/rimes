# macOS 27：特定应用切换输入法时闪退

[#90](https://github.com/scholay/rimes/issues/90) 的报告者在 macOS 27.0（26A428）的 App Store 沙盒版微信 4.1.5、QQ 6.9.93 中，遇到切换到 RIMES 1.1.0 时宿主应用闪退。报告者提供了 `CFRelease(NULL)` 调用栈，并通过自己的沙盒测试进程将问题定位到应用持有的旧输入源缓存。维护者尚未独立复现这条崩溃路径；这是恢复建议，不是已完成的系统修复。运行中应用何时重建缓存也没有得到维护者验证。

安装器会注册、启用并核验 RIMES 输入源，但不会清理其他应用的缓存。重启应用、退出登录或注册成功，都不能保证解决本报告的情况。

## 2026-10-09 更新：前提条件与安装器修复

维护者在同一系统版本（macOS 27.0，26A428）上用一个沙盒测试进程确认了这份报告的前提条件。沙盒应用通过系统级输入源缓存 `/System/Library/Caches/com.apple.IntlDataCache.le*` 识别输入法；这份缓存只有 root 能重建，系统通常在下一次登录时才刷新。1.1.1 及更早的安装器只以当前登录用户注册 RIMES，所以重新登录之前，新启动的沙盒进程查不到 RIMES，而同一台机器上的 Squirrel、微信输入法都能查到。这也是「安装后要退出登录或重启才能用」的来源。

1.1.1 之后的安装器在 `postinstall` 中以 root 调用 `TISRegisterInputSource`，完成系统级注册。在同一台机器上手动执行这一步后观察到：

- 系统级缓存立即包含 RIMES；
- 新启动的沙盒进程能查到 RIMES；
- 一个此前已经在运行的沙盒进程，无需重启即查到 RIMES；
- 微信、QQ、文本编辑里仍记录旧路径的按应用缓存，被系统自行丢弃。安装器仍然不清理任何应用的缓存。

`CFRelease(NULL)` 闪退本身没有在维护者机器上复现；上面验证的是它的前提条件被消除。新安装包经 PackageKit 实际安装的结果，待包含此修复的发布版本确认。

已安装 1.1.1 或更早版本时，安装包含此修复的版本即可。在此之前，退出登录并重新登录也会让系统重建这份缓存：维护者机器上该缓存的重建时间与登录时间一致，但没有做对照实验。下面按应用备份缓存的步骤保留为后备手段。

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

### Update (2026-10-09): precondition and installer fix

On the same OS build (macOS 27.0, 26A428) the maintainer confirmed the precondition of this report with a sandboxed test process. Sandboxed apps resolve input sources through the system-wide cache `/System/Library/Caches/com.apple.IntlDataCache.le*`. Only root can rebuild it, and macOS normally refreshes it at the next login. Installers up to 1.1.1 registered RIMES only as the logged-in user, so until that login a newly started sandboxed process could not find RIMES, while Squirrel and WeType on the same Mac were found. This is also why RIMES appeared to need a logout or restart after installing.

Installers after 1.1.1 call `TISRegisterInputSource` as root in `postinstall`. Running that step by hand on the same Mac had these effects:

- the system-wide cache listed RIMES immediately;
- a newly started sandboxed process found RIMES;
- a sandboxed process that was already running found RIMES without a relaunch;
- macOS itself dropped the per-app caches in WeChat, QQ and TextEdit that still recorded the old path. The installer still clears no app's cache.

The `CFRelease(NULL)` crash was not reproduced on the maintainer's Mac; what was verified is that its precondition is removed. An actual PackageKit install of the new package is still to be confirmed with the release that carries the fix.

With 1.1.1 or earlier installed, install a version that carries the fix. Until then, logging out and back in also makes macOS rebuild this cache: on the maintainer's Mac its rebuild time matches a login, but no controlled test was run. The per-app procedure below remains as a fallback.

### Per-app fallback

For one affected app only:

1. Select another working input method, save unsent text, and completely quit the affected app.
2. Use the currently logged-in GUI user's normal terminal, without `sudo` or root. Run the three read-only commands above: the UID from `id -u` must match the owner of `/dev/console` and must not be `0`. Stop if it does not.
3. Open the directory returned by `getconf DARWIN_USER_CACHE_DIR` in Finder, then only `com.tencent.xinWeChat` for WeChat or `com.tencent.qq` for QQ.
4. Check the exact two filenames above. The app directory must be a real directory, not a symbolic link; both files must exist and be regular files, not symbolic links or directories. The directory and both files must belong to the current user. Use `ls -ldn` to compare their numeric owners with `id -u`. Stop on missing files, unexpected types/owners, or errors; do not change permissions or expand the scope.
5. Move only those two files to a new empty local backup folder, keeping their names and recording the original paths. Do not delete them, use wildcards, scan other apps, or clear the whole cache. If a move fails, stop and retain whatever has already been backed up.
6. Start that app and try switching once. The reporter says rebuilding its cache restored switching. If the crash persists, use another input method and share a redacted crash stack plus OS/app versions in #90.

To revert, quit the same app, separately back up any newly generated files with these exact names, and return the original backups to their recorded paths. Keep the backups until acceptance. No step changes RIMES schemes/user dictionaries, app documents, or account data.
