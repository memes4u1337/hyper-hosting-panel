# HYPER-HOST v78

Исправлена передача `project_id` и действия из `hhctl` в `deploy_center.py`.

Причина: Bash вычислял массив аргументов в том же `local`, где только создавались
`project_id` и `action`, поэтому в argparse уходили пустые строки.

Исправлены действия:
- deploy
- start
- stop
- restart
- logs
- delete

Другие компоненты не изменяются.
