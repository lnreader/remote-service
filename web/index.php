<?php
declare(strict_types=1);

header('Content-Type: text/html; charset=UTF-8');
header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
header('Pragma: no-cache');

function h(string $value): string {
    return htmlspecialchars($value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function bytes_human(int|float $bytes): string {
    $bytes = max(0, (float)$bytes);
    $units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
    $i = 0;
    while ($bytes >= 1024 && $i < count($units) - 1) {
        $bytes /= 1024;
        $i++;
    }
    return $i === 0 ? sprintf('%.0f %s', $bytes, $units[$i]) : sprintf('%.2f %s', $bytes, $units[$i]);
}


function duration_human(int $seconds): string {
    $seconds = max(0, $seconds);
    $days = intdiv($seconds, 86400);
    $hours = intdiv($seconds % 86400, 3600);
    $minutes = intdiv($seconds % 3600, 60);
    if ($days > 0) {
        return sprintf('%dd %dh %dm', $days, $hours, $minutes);
    }
    if ($hours > 0) {
        return sprintf('%dh %dm', $hours, $minutes);
    }
    if ($minutes > 0) {
        return sprintf('%dm %ds', $minutes, $seconds % 60);
    }
    return sprintf('%ds', $seconds);
}

function normalized_origin(): array {
    $override = trim((string)getenv('PUBLIC_URL'));
    if ($override !== '') {
        $parts = parse_url($override);
        if (is_array($parts) && isset($parts['scheme'], $parts['host']) && in_array(strtolower((string)$parts['scheme']), ['http', 'https'], true)) {
            $origin = strtolower((string)$parts['scheme']) . '://' . (string)$parts['host'];
            if (isset($parts['port'])) {
                $origin .= ':' . (int)$parts['port'];
            }
            if (isset($parts['path']) && trim((string)$parts['path'], '/') !== '') {
                $origin .= '/' . trim((string)$parts['path'], '/');
            }
            return [rtrim($origin, '/'), strtolower((string)$parts['scheme']) === 'https', 'PUBLIC_URL'];
        }
    }

    $forwardedProto = trim(explode(',', (string)($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? ''))[0]);
    $scheme = in_array($forwardedProto, ['http', 'https'], true)
        ? $forwardedProto
        : (((string)($_SERVER['HTTPS'] ?? '') !== '' && (string)($_SERVER['HTTPS'] ?? '') !== 'off') ? 'https' : 'http');

    $forwardedHost = trim(explode(',', (string)($_SERVER['HTTP_X_FORWARDED_HOST'] ?? ''))[0]);
    $host = $forwardedHost !== '' ? $forwardedHost : (string)($_SERVER['HTTP_HOST'] ?? '');
    if (!preg_match('/^[A-Za-z0-9.\-\[\]:]+$/', $host)) {
        $host = 'host-unavailable';
    }
    return [$scheme . '://' . $host, $scheme === 'https', 'detected request'];
}

function api_healthy(): bool {
    $fp = @fsockopen('127.0.0.1', 8001, $errno, $errstr, 0.75);
    if ($fp === false) {
        return false;
    }
    stream_set_timeout($fp, 1);
    fwrite($fp, "GET /healthz HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    $status = fgets($fp, 256) ?: '';
    fclose($fp);
    return str_contains($status, ' 200 ');
}

function dir_stats(string $dir): array {
    $files = 0;
    $bytes = 0;
    $latest = 0;
    try {
        $it = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS),
            RecursiveIteratorIterator::LEAVES_ONLY
        );
        foreach ($it as $item) {
            if (!$item->isFile()) {
                continue;
            }
            $name = $item->getFilename();
            if (str_contains($name, '.upload-') && str_ends_with($name, '.part')) {
                continue;
            }
            $files++;
            $bytes += $item->getSize();
            $latest = max($latest, $item->getMTime());
        }
    } catch (UnexpectedValueException $e) {
        return ['files' => 0, 'bytes' => 0, 'latest' => 0, 'error' => true];
    }
    return ['files' => $files, 'bytes' => $bytes, 'latest' => $latest, 'error' => false];
}


function csrf_token(string $workspace, string $backupName): ?string {
    $secretPath = rtrim($workspace, '/') . '/.webui-auth/password';
    $secret = @file_get_contents($secretPath);

    if (!is_string($secret) || $secret === '') {
        return null;
    }

    return hash_hmac('sha256', 'delete-backup:' . $backupName, $secret);
}

function safe_backup_dir(string $workspace, string $backupName): string {
    if (
        $backupName === ''
        || str_contains($backupName, "\0")
        || basename($backupName) !== $backupName
        || !str_ends_with($backupName, '.backup')
    ) {
        throw new RuntimeException('Invalid backup name.');
    }

    $root = realpath($workspace);
    if ($root === false || !is_dir($root)) {
        throw new RuntimeException('Backup storage is unavailable.');
    }

    $candidate = $root . DIRECTORY_SEPARATOR . $backupName;

    if (is_link($candidate)) {
        throw new RuntimeException('Refusing to delete a symbolic link.');
    }

    $target = realpath($candidate);

    if (
        $target === false
        || !is_dir($target)
        || dirname($target) !== $root
    ) {
        throw new RuntimeException(
            'Backup does not exist or is outside storage.'
        );
    }

    return $target;
}

function backup_has_active_upload(
    string $runtimeDir,
    string $backupName
): bool {
    $statusFile = rtrim($runtimeDir, '/') . '/uploads.json';

    if (!is_readable($statusFile)) {
        return false;
    }

    $decoded = json_decode(
        (string)@file_get_contents($statusFile),
        true
    );

    if (
        !is_array($decoded)
        || !isset($decoded['uploads'])
        || !is_array($decoded['uploads'])
    ) {
        return false;
    }

    foreach ($decoded['uploads'] as $upload) {
        if (
            is_array($upload)
            && (string)($upload['backup_name'] ?? '') === $backupName
        ) {
            return true;
        }
    }

    return false;
}

function delete_backup_tree(string $target): void {
    $iterator = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator(
            $target,
            FilesystemIterator::SKIP_DOTS
        ),
        RecursiveIteratorIterator::CHILD_FIRST
    );

    foreach ($iterator as $item) {
        $itemPath = $item->getPathname();

        if ($item->isLink() || $item->isFile()) {
            if (!@unlink($itemPath)) {
                throw new RuntimeException(
                    'Could not delete file: '
                    . $item->getFilename()
                );
            }
            continue;
        }

        if ($item->isDir() && !@rmdir($itemPath)) {
            throw new RuntimeException(
                'Could not delete directory: '
                . $item->getFilename()
            );
        }
    }

    if (!@rmdir($target)) {
        throw new RuntimeException(
            'Could not remove the backup directory.'
        );
    }
}

$workspace = (string)(getenv('LNREADER_STORAGE_DIR') ?: '/home/lnreader/.LNReader');
$runtimeDir = (string)(getenv('LNREADER_RUNTIME_DIR') ?: '/run/lnreader');
$uiSlug = (string)(getenv('WEB_UI_SLUG') ?: 'lnr-vault-7f3c9');
$appVersion = (string)(getenv('APP_VERSION') ?: 'unknown');
$dashboardPath = '/' . trim($uiSlug, '/') . '/';

$requestMethod = strtoupper(
    (string)($_SERVER['REQUEST_METHOD'] ?? 'GET')
);

$confirmBackup = null;
$confirmToken = null;
$confirmStats = null;
$notice = null;
$error = null;

if ($requestMethod === 'POST') {
    $action = (string)($_POST['action'] ?? '');
    $backupName = (string)($_POST['backup'] ?? '');
    $providedToken = (string)($_POST['csrf'] ?? '');

    try {
        $target = safe_backup_dir(
            $workspace,
            $backupName
        );

        $expectedToken = csrf_token(
            $workspace,
            $backupName
        );

        if (
            $expectedToken === null
            || $providedToken === ''
            || !hash_equals(
                $expectedToken,
                $providedToken
            )
        ) {
            throw new RuntimeException(
                'Invalid or expired confirmation token.'
            );
        }

        if (
            backup_has_active_upload(
                $runtimeDir,
                $backupName
            )
        ) {
            throw new RuntimeException(
                'This backup currently has an active upload '
                . 'and cannot be deleted.'
            );
        }

        if ($action === 'confirm') {
            $confirmBackup = $backupName;
            $confirmToken = $expectedToken;
            $confirmStats = dir_stats($target);
        } elseif ($action === 'delete') {
            delete_backup_tree($target);

            header(
                'Location: '
                . $dashboardPath
                . '?deleted='
                . rawurlencode($backupName),
                true,
                303
            );
            exit;
        } else {
            throw new RuntimeException(
                'Unknown backup action.'
            );
        }
    } catch (Throwable $exception) {
        http_response_code(400);
        $error = $exception->getMessage();
    }
} elseif (
    !in_array(
        $requestMethod,
        ['GET', 'HEAD'],
        true
    )
) {
    http_response_code(405);
    header('Allow: GET, HEAD, POST');
    $error = 'Method not allowed.';
}

if (
    $requestMethod === 'GET'
    && isset($_GET['deleted'])
    && is_string($_GET['deleted'])
    && $_GET['deleted'] !== ''
) {
    $notice = 'Deleted backup '
        . $_GET['deleted']
        . '.';
}

[$appUrl, $isHttps, $urlSource] = normalized_origin();
$healthy = api_healthy();
$startedAtRaw = @file_get_contents(rtrim($runtimeDir, '/') . '/started_at');
$startedAt = is_string($startedAtRaw) && ctype_digit(trim($startedAtRaw)) ? (int)trim($startedAtRaw) : 0;
$uptime = $startedAt > 0 ? max(0, time() - $startedAt) : null;

$backups = [];
$totalBytes = 0;
$totalFiles = 0;
$backupDirs = glob(rtrim($workspace, '/') . '/*.backup', GLOB_ONLYDIR) ?: [];
sort($backupDirs, SORT_NATURAL | SORT_FLAG_CASE);
foreach ($backupDirs as $dir) {
    $stats = dir_stats($dir);
    $stats['name'] = basename($dir);
    $backups[] = $stats;
    $totalBytes += (int)$stats['bytes'];
    $totalFiles += (int)$stats['files'];
}

$activeUploads = [];
$statusFile = rtrim($runtimeDir, '/') . '/uploads.json';
if (is_readable($statusFile)) {
    $decoded = json_decode((string)file_get_contents($statusFile), true);
    if (is_array($decoded) && isset($decoded['uploads']) && is_array($decoded['uploads'])) {
        foreach ($decoded['uploads'] as $id => $upload) {
            if (!is_array($upload)) {
                continue;
            }
            $upload['_id'] = (string)$id;
            $activeUploads[] = $upload;
        }
    }
}
usort($activeUploads, fn(array $a, array $b): int => ((float)($a['started_at'] ?? 0)) <=> ((float)($b['started_at'] ?? 0)));

$activeBackupNames = [];

foreach ($activeUploads as $upload) {
    $activeName = (string)(
        $upload['backup_name'] ?? ''
    );

    if ($activeName !== '') {
        $activeBackupNames[$activeName] = true;
    }
}

$diskTotal = @disk_total_space($workspace);
$diskFree = @disk_free_space($workspace);
$diskUsedPct = (is_float($diskTotal) && $diskTotal > 0 && is_float($diskFree)) ? (($diskTotal - $diskFree) / $diskTotal * 100) : null;
$latestBackup = null;
foreach ($backups as $backup) {
    if ($latestBackup === null || (int)$backup['latest'] > (int)$latestBackup['latest']) {
        $latestBackup = $backup;
    }
}
$now = time();
?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<?php if ($confirmBackup === null && $error === null): ?>
<meta http-equiv="refresh" content="5">
<?php endif; ?>
<title>LNReader Vault Status</title>
<style>
:root{color-scheme:dark;--bg:#0c1017;--panel:#141b25;--panel2:#101720;--line:#293343;--text:#e7edf5;--muted:#9ba9ba;--ok:#70d59a;--warn:#efc66b;--bad:#ff8b8b;--accent:#9ec7ff}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}.wrap{max-width:1180px;margin:auto;padding:28px 18px 48px}h1,h2{margin:0 0 12px}h1{font-size:28px}h2{font-size:18px}.sub{color:var(--muted);margin:0 0 24px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:14px;margin:0 0 22px}.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px;min-width:0}.label{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.08em}.value{font-size:22px;font-weight:700;margin-top:5px;overflow-wrap:anywhere}.ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}code{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;background:#0a0f16;border:1px solid var(--line);border-radius:6px;padding:2px 6px}.url{display:block;padding:12px;margin-top:8px;white-space:normal;overflow-wrap:anywhere;color:var(--accent)}table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:10px 8px;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.06em}.bar{height:8px;background:#0a0f16;border:1px solid var(--line);border-radius:999px;overflow:hidden;margin-top:7px}.bar>span{display:block;height:100%;background:var(--accent)}.note{color:var(--muted);font-size:13px}.security{border-left:3px solid var(--warn)}.footer{margin-top:20px;color:var(--muted);font-size:12px}@media(max-width:700px){.wrap{padding:18px 10px}table{display:block;overflow-x:auto}.value{font-size:19px}}

.action-form{margin:0}
.actions{white-space:nowrap}
.button,.danger-button{
    display:inline-block;
    border:1px solid var(--line);
    border-radius:7px;
    padding:7px 11px;
    font:inherit;
    font-weight:650;
    text-decoration:none;
    cursor:pointer;
    background:#18212d;
    color:var(--text)
}
.button:hover{background:#202c3b}
.danger-button{
    border-color:#743f49;
    background:#341d23;
    color:#ffb3bd
}
.danger-button:hover{background:#47242d}
.confirm-card{border-left:3px solid var(--bad)}
.success-card{border-left:3px solid var(--ok)}
.error-card{border-left:3px solid var(--bad)}
.confirm-actions{
    display:flex;
    gap:10px;
    align-items:center;
    flex-wrap:wrap;
    margin-top:14px
}

</style>
</head>
<body>
<main class="wrap">
  <h1>LNReader Vault Status</h1>
  <p class="sub">Authenticated backup management console. Auto-refreshes every 5 seconds when no action is pending.</p>

  <?php if ($notice !== null): ?>
    <section
      class="card success-card"
      style="margin-bottom:14px"
      role="status"
    >
      <strong><?= h($notice) ?></strong>
    </section>
  <?php endif; ?>

  <?php if ($error !== null): ?>
    <section
      class="card error-card"
      style="margin-bottom:14px"
      role="alert"
    >
      <strong>Backup action failed.</strong>
      <p><?= h($error) ?></p>
    </section>
  <?php endif; ?>

  <?php if (
      $confirmBackup !== null
      && $confirmToken !== null
  ): ?>
    <section
      class="card confirm-card"
      style="margin-bottom:14px"
      aria-labelledby="delete-confirm-title"
    >
      <h2 id="delete-confirm-title">
        Delete backup?
      </h2>

      <p>
        Permanently delete
        <strong><?= h($confirmBackup) ?></strong>?
        This cannot be undone.
      </p>

      <?php if (is_array($confirmStats)): ?>
        <p class="note">
          <?= (int)$confirmStats['files'] ?> files ·
          <?= h(
              bytes_human(
                  (int)$confirmStats['bytes']
              )
          ) ?>
        </p>
      <?php endif; ?>

      <div class="confirm-actions">
        <form
          method="post"
          action="<?= h($dashboardPath) ?>"
        >
          <input
            type="hidden"
            name="action"
            value="delete"
          >
          <input
            type="hidden"
            name="backup"
            value="<?= h($confirmBackup) ?>"
          >
          <input
            type="hidden"
            name="csrf"
            value="<?= h($confirmToken) ?>"
          >

          <button
            class="danger-button"
            type="submit"
          >
            Delete permanently
          </button>
        </form>

        <a
          class="button"
          href="<?= h($dashboardPath) ?>"
        >
          Cancel
        </a>
      </div>
    </section>
  <?php endif; ?>

  <section class="grid" aria-label="Service summary">
    <div class="card"><div class="label">API</div><div class="value <?= $healthy ? 'ok' : 'bad' ?>"><?= $healthy ? 'Healthy' : 'Unavailable' ?></div></div>
    <div class="card"><div class="label">Backups</div><div class="value"><?= count($backups) ?></div></div>
    <div class="card"><div class="label">Backup files</div><div class="value"><?= $totalFiles ?></div></div>
    <div class="card"><div class="label">Stored backup data</div><div class="value"><?= h(bytes_human($totalBytes)) ?></div></div>
    <div class="card"><div class="label">Active uploads</div><div class="value <?= count($activeUploads) ? 'warn' : 'ok' ?>"><?= count($activeUploads) ?></div></div>
    <div class="card"><div class="label">Storage free</div><div class="value"><?= is_float($diskFree) ? h(bytes_human($diskFree)) : 'Unknown' ?></div><div class="note"><?= $diskUsedPct === null ? '' : h(number_format($diskUsedPct, 1) . '% used') ?></div></div>
    <div class="card"><div class="label">Container uptime</div><div class="value"><?= $uptime === null ? 'Unknown' : h(duration_human($uptime)) ?></div></div>
    <div class="card"><div class="label">Image version</div><div class="value"><?= h($appVersion) ?></div></div>
    <div class="card"><div class="label">Latest backup</div><div class="value"><?= $latestBackup === null ? 'None' : h((string)$latestBackup['name']) ?></div><div class="note"><?= $latestBackup !== null && (int)$latestBackup['latest'] > 0 ? h(gmdate('Y-m-d H:i:s \U\T\C', (int)$latestBackup['latest'])) : '' ?></div></div>
  </section>

  <section class="card" aria-labelledby="app-url-title">
    <h2 id="app-url-title">LNReader app server URL</h2>
    <p>Use this base URL in <strong>LNReader → Settings → Backup → Self Host Backup</strong>:</p>
    <code class="url"><?= h($appUrl) ?></code>
    <p class="note">Source: <?= h($urlSource) ?>. The dashboard path <code>/<?= h($uiSlug) ?>/</code> is <strong>not</strong> part of the app URL.</p>
    <?php if (!$isHttps): ?>
      <p class="warn"><strong>HTTPS is not detected.</strong> This is acceptable for a trusted LAN/VPN, but do not expose HTTP Basic Auth or the LNReader API directly to the public Internet.</p>
    <?php endif; ?>
  </section>

  <section class="card" style="margin-top:14px" aria-labelledby="active-title">
    <h2 id="active-title">Current backup uploads</h2>
    <?php if (!$activeUploads): ?>
      <p class="note">No upload is currently running.</p>
    <?php else: ?>
      <table>
        <thead><tr><th>Backup</th><th>File</th><th>Progress</th><th>Received</th><th>Rate</th><th>ETA</th><th>Elapsed</th></tr></thead>
        <tbody>
        <?php foreach ($activeUploads as $upload):
          $received = max(0, (int)($upload['bytes_received'] ?? 0));
          $total = max(0, (int)($upload['total_bytes'] ?? 0));
          $pct = $total > 0 ? min(100, $received / $total * 100) : 0;
          $elapsed = max(0, $now - (int)($upload['started_at'] ?? $now));
          $rate = $elapsed > 0 ? $received / $elapsed : 0;
          $eta = ($rate > 0 && $total > $received) ? (int)ceil(($total - $received) / $rate) : 0;
        ?>
          <tr>
            <td><?= h((string)($upload['backup_name'] ?? 'unknown')) ?></td>
            <td><?= h((string)($upload['filename'] ?? 'unknown')) ?></td>
            <td><?= h(number_format($pct, 1)) ?>%<div class="bar" aria-label="<?= h(number_format($pct, 1)) ?> percent"><span style="width:<?= h(number_format($pct, 2, '.', '')) ?>%"></span></div></td>
            <td><?= h(bytes_human($received)) ?> / <?= h(bytes_human($total)) ?></td>
            <td><?= $rate > 0 ? h(bytes_human($rate) . '/s') : '—' ?></td>
            <td><?= $eta > 0 ? h(duration_human($eta)) : '—' ?></td>
            <td><?= h(duration_human($elapsed)) ?></td>
          </tr>
        <?php endforeach; ?>
        </tbody>
      </table>
    <?php endif; ?>
  </section>

  <section class="card" style="margin-top:14px" aria-labelledby="backups-title">
    <h2 id="backups-title">Stored backups</h2>
    <?php if (!$backups): ?>
      <p class="note">No <code>*.backup</code> directories were found yet.</p>
    <?php else: ?>
      <table>
        <thead><tr><th>Name</th><th>Files</th><th>Size</th><th>Last modified</th><th>Actions</th></tr></thead>
        <tbody>
        <?php foreach ($backups as $backup): ?>
          <tr>
            <td><?= h((string)$backup['name']) ?></td>
            <td><?= (int)$backup['files'] ?></td>
            <td><?= h(bytes_human((int)$backup['bytes'])) ?></td>
            <td><?= (int)$backup['latest'] > 0 ? h(gmdate('Y-m-d H:i:s \U\T\C', (int)$backup['latest'])) : 'Unknown' ?></td>
          <?php
            $backupName = (string)$backup['name'];
            $deleteToken = csrf_token(
                $workspace,
                $backupName
            );
            $backupIsActive = isset(
                $activeBackupNames[$backupName]
            );
          ?>

          <td class="actions">
            <?php if ($backupIsActive): ?>
              <span class="note">Uploading</span>

            <?php elseif ($deleteToken === null): ?>
              <span class="note">
                Delete unavailable
              </span>

            <?php else: ?>
              <form
                class="action-form"
                method="post"
                action="<?= h($dashboardPath) ?>"
              >
                <input
                  type="hidden"
                  name="action"
                  value="confirm"
                >
                <input
                  type="hidden"
                  name="backup"
                  value="<?= h($backupName) ?>"
                >
                <input
                  type="hidden"
                  name="csrf"
                  value="<?= h($deleteToken) ?>"
                >

                <button
                  class="danger-button"
                  type="submit"
                >
                  Delete
                </button>
              </form>
            <?php endif; ?>
          </td>
          </tr>
        <?php endforeach; ?>
        </tbody>
      </table>
    <?php endif; ?>
  </section>

  <section class="card security" style="margin-top:14px" aria-labelledby="security-title">
    <h2 id="security-title">Security</h2>
    <p class="note">This console is protected by Nginx HTTP Basic Auth using a bcrypt <code>htpasswd</code> file. Backup deletion uses authenticated POST requests, CSRF tokens, a second confirmation step, path containment checks, and refuses to delete backups with active uploads.</p>
    <p class="note">The LNReader backup API itself remains unauthenticated for client compatibility. Keep direct port 8000 on LAN/VPN, or put the service behind HTTPS on a reverse proxy. Do not assume the unusual dashboard path protects the API.</p>
  </section>

  <div class="footer">Generated <?= h(gmdate('Y-m-d H:i:s \U\T\C')) ?> · Dashboard /<?= h($uiSlug) ?>/</div>
</main>
</body>
</html>
