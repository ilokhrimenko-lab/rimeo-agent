# Раскладка окна RimeoAgent.dmg для dmgbuild.
#
# Почему dmgbuild, а не Finder/AppleScript: Finder жёстко снапит иконки к своей сетке
# (замерено: заданные 45/263 он превращает в 95/313), поэтому попасть иконкой в рамку
# на фоне через него невозможно. Плюс на CI нет Finder'а. dmgbuild пишет .DS_Store сам.
#
# Координаты — центры иконок из макета «DMG — C» (артборд 660×400).

import os.path
import subprocess

# dmgbuild выполняет этот файл через exec(), поэтому __file__ здесь не существует —
# путь к папке приезжает через -D here=...
app = defines.get("app", "dist/RimeoAgent.app")  # noqa: F821 — defines приходит от dmgbuild
here = defines.get("here", ".")  # noqa: F821
appname = os.path.basename(app)

# ⚠️ Размер образа задаём ЯВНО, с запасом.
# Без этого dmgbuild считает его сам и делает впритык, а копирует бандл через
# `subprocess.call(["ditto", ...])` — БЕЗ проверки кода возврата. Если места не хватило,
# ditto молча не докопирует последние файлы, и образ соберётся «успешно» без них.
# Один раз это уже случилось: из бандла пропали Contents/CodeResources (тикет нотаризации)
# и Contents/Library/LaunchAgents (автозапуск), причём подпись бандла при этом сломалась.
_app_kb = int(subprocess.check_output(["du", "-sk", app]).split()[0])
size = "{}M".format(_app_kb // 1024 + 128)

format = "UDZO"
compression_level = 9
files = [app]
symlinks = {"Applications": "/Applications"}

background = os.path.join(here, "background.tiff")

# Размер окна = размеру фона. window_rect — это КОНТЕНТ, титульная полоса сверху.
#
# ⚠️ Позиция окна абсолютная, и Y здесь отсчитывается ОТ НИЗА ЭКРАНА, а не от верха.
# Finder кладёт верх окна на (высота экрана − y − высота окна). Именно поэтому «y=120»
# выглядит не «почти у верхней кромки», а «внизу слева»: на экране высотой 1440 это 920.
#
# Центрировать динамически нельзя — координата в образе одна на всех, а экран
# пользователя на этапе сборки неизвестен. Целимся в ноутбуки (типичный пользователь):
#   MacBook Air 13" (1440×900):  окно встанет в (405, 230), центр был бы (390, 250)
#   MacBook Pro 14" (1512×982):  окно встанет в (405, 312), центр был бы (426, 291)
# На большом внешнем мониторе окно окажется левее и ниже центра — осознанный размен.
window_rect = ((405, 270), (660, 400))
default_view = "icon-view"

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 96
text_size = 12
label_pos = "bottom"
arrange_by = None

# Центры иконок в макете — (70,164) и (288,164). Finder рисует иконку на 25px правее
# координаты, записанной в .DS_Store (проверено: пишем 70 — Finder показывает 95),
# поэтому по X координаты сдвинуты на -25. Без этого папка не попадает в пунктирную
# рамку, нарисованную на фоне.
icon_locations = {
    appname: (45, 164),
    "Applications": (263, 164),
}
