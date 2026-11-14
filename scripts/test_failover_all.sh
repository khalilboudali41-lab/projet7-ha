#!/usr/bin/env bash
# Projet 7 – enchaîne les 5 tests de bascule (≈ 6 min) ; s'arrête si l'état nominal n'est pas retrouvé
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rc=0
for t in web app dbproxy db lb; do
  "$P7_ROOT/scripts/test_failover_$t.sh" || rc=1
  "$P7_ROOT/scripts/healthcheck.sh" -q || die "état nominal non retrouvé après le test $t – arrêt"
done
(( rc == 0 )) && ok "5/5 tests réussis" || fail "au moins un test en échec – voir docs/resultats-tests/README.md"
exit $rc
