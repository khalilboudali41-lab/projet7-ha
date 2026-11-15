<?php
/**
 * Projet 7 – application « vitrine HA »
 * Affiche, pour chaque requête : le load balancer (HAProxy), le conteneur web (nginx), le conteneur app
 * (php-fpm) qui l'ont servie, le nœud Galera utilisé, l'heure et un compteur
 * stocké en base. Application sans état (aucune session) : n'importe quel
 * serveur web/app peut servir n'importe quelle requête.
 *
 * Routes : /  (page)  ·  /api (JSON)  ·  /healthz  ·  /healthz/db  ·  /style.css
 */
declare(strict_types=1);

const DB_DSN  = 'mysql:host=db;port=3306;dbname=vitrine;charset=utf8mb4';
const DB_USER = 'vitrine';

$webNode = preg_replace('/[^A-Za-z0-9._-]/', '', (string)($_SERVER['WEB_NODE'] ?? 'inconnu'));
$appNode = gethostname() ?: 'inconnu';
// Positionné (et écrasé) par HAProxy ; filtré comme WEB_NODE
$lbNode  = preg_replace('/[^A-Za-z0-9._-]/', '', (string)($_SERVER['HTTP_X_LB_NODE'] ?? '')) ?: '—';
header('X-App-Node: ' . $appNode);

function db_connect(): PDO
{
    static $password = null;
    $password ??= trim((string)file_get_contents('/run/secrets/db_app_password'));
    return new PDO(DB_DSN, DB_USER, $password, [
        PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_TIMEOUT            => 2,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        PDO::ATTR_EMULATE_PREPARES   => false,
    ]);
}

/**
 * Exécute $fn avec une connexion neuve ; en cas d'erreur SQL (bascule de
 * l'écrivain Galera, dbproxy redémarré…), réessaie UNE fois après 300 ms.
 * Masque la fenêtre de détection des health checks (~2-4 s mesurée en phase 3).
 */
function with_db(callable $fn): mixed
{
    $last = null;
    for ($attempt = 1; $attempt <= 2; $attempt++) {
        try {
            return $fn(db_connect());
        } catch (PDOException $e) {
            $last = $e;
            error_log(sprintf('[vitrine] tentative %d en échec : %s', $attempt, $e->getMessage()));
            usleep(300_000);
        }
    }
    throw $last;
}

/** Enregistre la visite (transaction atomique) et lit l'état du cluster. */
function record_visit(string $web, string $app): array
{
    return with_db(function (PDO $db) use ($web, $app): array {
        $db->beginTransaction();
        $db->exec('UPDATE compteur SET valeur = LAST_INSERT_ID(valeur + 1) WHERE id = 1');
        $count  = (int)$db->query('SELECT LAST_INSERT_ID()')->fetchColumn();
        // Nom du nœud Galera (galera1, galera2…) : @@hostname donnerait le nom de la
        // VM quand Galera tourne en réseau hôte (multi-VM)
        $dbNode = (string)$db->query('SELECT @@wsrep_node_name')->fetchColumn();
        $db->prepare('INSERT INTO visites (web, app, db_node) VALUES (?, ?, ?)')
           ->execute([$web, $app, $dbNode]);
        $db->commit();

        $status = $db->query("SHOW GLOBAL STATUS WHERE Variable_name IN
            ('wsrep_cluster_size','wsrep_cluster_status','wsrep_local_state_comment')")
            ->fetchAll(PDO::FETCH_KEY_PAIR);
        $recent = $db->query('SELECT horodatage, web, app, db_node FROM visites ORDER BY id DESC LIMIT 8')
            ->fetchAll();
        return [
            'compteur'     => $count,
            'db_node'      => $dbNode,
            'cluster_size' => (int)($status['wsrep_cluster_size'] ?? 0),
            'cluster'      => ($status['wsrep_cluster_status'] ?? '?') . ' / ' . ($status['wsrep_local_state_comment'] ?? '?'),
            'recent'       => $recent,
        ];
    });
}

function h(mixed $v): string
{
    return htmlspecialchars((string)$v, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

// -----------------------------------------------------------------------------
$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
$now  = new DateTimeImmutable('now');

switch ($path) {
    // Health check HAProxy : le serveur web ET un php-fpm répondent (sans dépendre de la base,
    // pour qu'une panne DB ne retire pas tous les serveurs web du pool)
    case '/healthz':
        header('Content-Type: text/plain; charset=utf-8');
        header('Cache-Control: no-store');
        echo "ok web={$webNode} app={$appNode}\n";
        exit;

    // Contrôle profond : la chaîne complète jusqu'à Galera fonctionne
    case '/healthz/db':
        header('Content-Type: text/plain; charset=utf-8');
        header('Cache-Control: no-store');
        try {
            $node = with_db(fn (PDO $db) => (string)$db->query('SELECT @@wsrep_node_name')->fetchColumn());
            echo "ok db={$node}\n";
        } catch (Throwable) {
            http_response_code(503);
            echo "db indisponible\n";
        }
        exit;

    case '/style.css':
        header('Content-Type: text/css; charset=utf-8');
        header('Cache-Control: public, max-age=3600');
        readfile(__DIR__ . '/style.css');
        exit;

    case '/api':
        header('Content-Type: application/json; charset=utf-8');
        header('Cache-Control: no-store');
        try {
            $v = record_visit($webNode, $appNode);
            unset($v['recent']);
            echo json_encode(['lb' => $lbNode, 'web' => $webNode, 'app' => $appNode, 'heure' => $now->format(DATE_ATOM)] + $v,
                JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), "\n";
        } catch (Throwable) {
            http_response_code(503);
            echo json_encode(['web' => $webNode, 'app' => $appNode, 'erreur' => 'base indisponible']), "\n";
        }
        exit;

    case '/':
        break;

    default:
        http_response_code(404);
        header('Content-Type: text/plain; charset=utf-8');
        echo "404\n";
        exit;
}

// --- Page HTML ----------------------------------------------------------------
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
$refresh = isset($_GET['refresh']) ? max(1, min(30, (int)$_GET['refresh'])) : 0;
try {
    $v = record_visit($webNode, $appNode);
    $error = null;
} catch (Throwable) {
    http_response_code(503);
    $v = null;
    $error = 'Base de données indisponible – nouvelle tentative au prochain rafraîchissement.';
}
?>
<!doctype html>
<html lang="fr">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <?php if ($refresh): ?><meta http-equiv="refresh" content="<?= $refresh ?>"><?php endif; ?>
  <title>Vitrine HA – Projet 7</title>
  <link rel="stylesheet" href="/style.css">
</head>
<body>
<main>
  <header>
    <h1>Vitrine HA</h1>
    <p class="sub">Projet 7 · architecture N-tiers haute disponibilité · www.projet7.local</p>
  </header>

  <?php if ($error): ?><p class="alert"><?= h($error) ?></p><?php endif; ?>

  <section class="cards">
    <article class="card"><h2>Load balancer</h2><p class="val"><?= h($lbNode) ?></p><p class="hint">HAProxy · VIP</p></article>
    <article class="card"><h2>Serveur web</h2><p class="val"><?= h($webNode) ?></p><p class="hint">nginx</p></article>
    <article class="card"><h2>Serveur app</h2><p class="val"><?= h($appNode) ?></p><p class="hint">php-fpm</p></article>
    <article class="card"><h2>Nœud Galera</h2><p class="val"><?= h($v['db_node'] ?? '—') ?></p><p class="hint">via dbproxy</p></article>
    <article class="card"><h2>Heure serveur</h2><p class="val"><?= h($now->format('H:i:s')) ?></p><p class="hint"><?= h($now->format('d/m/Y')) ?></p></article>
    <article class="card accent"><h2>Compteur</h2><p class="val"><?= h(isset($v) ? number_format($v['compteur'], 0, ',', ' ') : '—') ?></p><p class="hint">visites en base</p></article>
  </section>

  <?php if ($v): ?>
  <p class="cluster">Cluster Galera : <strong><?= h($v['cluster_size']) ?> nœud(s)</strong> · <?= h($v['cluster']) ?></p>

  <section>
    <h2>Dernières requêtes</h2>
    <div class="table-wrap">
      <table>
        <thead><tr><th>Horodatage</th><th>Web</th><th>App</th><th>Galera</th></tr></thead>
        <tbody>
        <?php foreach ($v['recent'] as $r): ?>
          <tr><td><?= h(substr($r['horodatage'], 11)) ?></td><td><?= h($r['web']) ?></td><td><?= h($r['app']) ?></td><td><?= h($r['db_node']) ?></td></tr>
        <?php endforeach; ?>
        </tbody>
      </table>
    </div>
  </section>
  <?php endif; ?>

  <footer>
    <?php if ($refresh): ?>
      Rafraîchissement automatique toutes les <?= $refresh ?> s · <a href="/">arrêter</a>
    <?php else: ?>
      <a href="/?refresh=2">Rafraîchir automatiquement (démo de bascule)</a>
    <?php endif; ?>
  </footer>
</main>
</body>
</html>
