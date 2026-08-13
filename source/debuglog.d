module debuglog;

import std.stdio;
import std.format;
import std.datetime.systime;

// Nur das Logging, damit reine Datenmodule (mapping, composer, keysyms) nicht
// das Anwendungsmodul ananeo importieren muessen, um eine Zeile auszugeben.

version(FileLogging) {
    File logFile;

    static this() {
        logFile = File("ananeo_log.txt", "a+");
    }
}

void debugWriteln(T...)(T args) nothrow {
    debug {
        writeln(args);
    }

    version(FileLogging) {
        try {
        auto currTime = Clock.currTime();
        string timeString = format("%04d-%02d-%02d %02d:%02d:%02d.%03d ", currTime.year(), currTime.month(), currTime.day(), currTime.hour(), currTime.minute(), currTime.second(), cast(int) currTime.fracSecs().total!"msecs");
        logFile.writeln(timeString, args);
        logFile.flush();  // flush immediately in case we crash
        } catch (Exception e) {}
    }
}
