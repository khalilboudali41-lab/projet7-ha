# Résultats des tests de bascule

Généré automatiquement par `scripts/test_failover_*.sh` (le plus récent en bas).

| Date | Test | Panne | Indispo. max | Requêtes en échec | Verdict | Rapport |
|---|---|---|---|---|---|---|
| 14/11/2026 15:26:04 | web | docker kill web1 web2 (arrêt brutal, SIGKILL) | 2.2 s | 1 / 199 | ✅ RÉUSSI | [20261114-152604_web.md](20261114-152604_web.md) |
| 14/11/2026 15:28:12 | web | docker kill web1 web2 (arrêt brutal, SIGKILL) | 0.0 s | 0 / 205 | ✅ RÉUSSI | [20261114-152812_web.md](20261114-152812_web.md) |
| 14/11/2026 15:29:04 | app | docker kill app1 app2 (arrêt brutal, SIGKILL) | 2.2 s | 2 / 168 | ✅ RÉUSSI | [20261114-152904_app.md](20261114-152904_app.md) |
| 14/11/2026 15:31:42 | app | docker kill app1 app2 (arrêt brutal, SIGKILL) | 0.0 s | 0 / 190 | ✅ RÉUSSI | [20261114-153142_app.md](20261114-153142_app.md) |
| 14/11/2026 15:32:35 | dbproxy | docker kill dbproxy1 (l'alias « db » ne pointe plus que sur dbproxy2) | 0.0 s | 0 / 212 | ✅ RÉUSSI | [20261114-153235_dbproxy.md](20261114-153235_dbproxy.md) |
| 14/11/2026 15:33:27 | db | docker kill galera1 (arrêt brutal du nœud qui reçoit les écritures) | 6.6 s | 3 / 223 | ❌ ÉCHEC (1 contrôle(s)) | [20261114-153327_db.md](20261114-153327_db.md) |
| 14/11/2026 15:35:40 | db | docker kill galera1 (arrêt brutal du nœud qui reçoit les écritures) | 4.0 s | 2 / 207 | ✅ RÉUSSI | [20261114-153540_db.md](20261114-153540_db.md) |
| 14/11/2026 15:36:47 | lb | docker kill lb1 (HAProxy + keepalived du MASTER tués, sans libération propre de la VIP) | 3.6 s | 3 / 215 | ✅ RÉUSSI | [20261114-153647_lb.md](20261114-153647_lb.md) |
| 14/11/2026 15:37:47 | web | docker kill web1 web2 (arrêt brutal, SIGKILL) | 0.2 s | 1 / 210 | ✅ RÉUSSI | [20261114-153747_web.md](20261114-153747_web.md) |
| 14/11/2026 15:38:38 | app | docker kill app1 app2 (arrêt brutal, SIGKILL) | 0.0 s | 0 / 191 | ✅ RÉUSSI | [20261114-153838_app.md](20261114-153838_app.md) |
| 14/11/2026 15:39:28 | dbproxy | docker kill dbproxy1 (l'alias « db » ne pointe plus que sur dbproxy2) | 0.0 s | 0 / 212 | ✅ RÉUSSI | [20261114-153928_dbproxy.md](20261114-153928_dbproxy.md) |
| 14/11/2026 15:40:18 | db | docker kill galera1 (arrêt brutal du nœud qui reçoit les écritures) | 4.0 s | 2 / 210 | ✅ RÉUSSI | [20261114-154018_db.md](20261114-154018_db.md) |
| 14/11/2026 15:41:14 | lb | docker kill lb1 (HAProxy + keepalived du MASTER tués, sans libération propre de la VIP) | 3.6 s | 3 / 217 | ✅ RÉUSSI | [20261114-154114_lb.md](20261114-154114_lb.md) |
| 14/11/2026 15:43:24 | web | docker kill web1 web2 (arrêt brutal, SIGKILL) | 0.0 s | 0 / 207 | ✅ RÉUSSI | [20261114-154324_web.md](20261114-154324_web.md) |
| 14/11/2026 15:44:13 | web | docker kill web1 web2 (arrêt brutal, SIGKILL) | 0.0 s | 0 / 205 | ✅ RÉUSSI | [20261114-154413_web.md](20261114-154413_web.md) |
| 15/11/2026 23:13:40 | vm-smoke | aucune (validation de la mesure) | 0.0 s | 0 / 162 | ✅ RÉUSSI | [20261115-231340_vm-smoke.md](20261115-231340_vm-smoke.md) |
| 17/11/2026 15:18:48 | vm-smoke | aucune (validation de la mesure) | 0.0 s | 0 / 162 | ✅ RÉUSSI | [20261117-151848_vm-smoke.md](20261117-151848_vm-smoke.md) |
