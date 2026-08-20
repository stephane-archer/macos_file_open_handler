/// Public API for receiving files opened through macOS.
library;

export 'src/macos_file_open_handler.dart'
    show
        MacosFileOpenCallback,
        MacosFileOpenErrorCallback,
        MacosFileOpenHandler,
        MacosFileOpenSubscription,
        MacosOpenedFile;
