import sys

from PySide6.QtWidgets import QApplication, QLabel


def main():
    app = QApplication(sys.argv)
    label = QLabel("hello-clock: infernixos extension example")
    label.resize(360, 120)
    label.setStyleSheet("font-size: 14px;")
    label.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
