module midifile.midifile;

import std.file;
import std.string;
import std.range;
import std.exception;

enum MIDIEventType : ubyte
{
    NoteOff = 0x80,
    NoteOn = 0x90,
    KeyAfterTouch = 0xA0,
    ControlChange = 0xB0,
    ProgramChange = 0xC0,
    ChannelAfterTouch = 0xD0,
    PitchWheel = 0xE0,
    SYSEX = 0xF0,
    Custom = 0xFF
}

enum MIDIEvents : ubyte
{
    SequenceNumber = 0x00, // Sequence Number
    Text = 0x01, // Text
    Copyright = 0x02, // Copyright
    TrackName = 0x03, // Sequence/Track Name
    Instrument = 0x04, // Instrument
    Lyric = 0x05, // Lyric
    Marker = 0x06, // Marker
    CuePoint = 0x07, // Cue Point
    PatchName = 0x08, // Program (Patch) Name
    PortName = 0x09, // Device (Port) Name
    EndOfTrack = 0x2F, // End of Track
    Tempo = 0x51, // Tempo
    SMPTE = 0x54, // SMPTE Offset
    TimeSignature = 0x58, // Time Signature
    KeySignature = 0x59, // Key Signature
    Custom = 0x7F, // Proprietary Event
}

struct MThd_Chunk
{
    ubyte[4] id;   // 'M','T','h','d'
    uint     length;

    ushort   format;
    ushort   numTracks;
    ushort   ticksPerBeat;
}

struct MTrk_Chunk
{
    ubyte[4] id;   // 'M','T','r','k' */
    uint     length;
}

auto getFront(R)(ref R range)
{
    auto f = range.front();
    range.popFront();
    return f;
}

T[] getFrontN(R, T = ElementType!R)(ref R range, size_t n)
{
    T[] f = range[0..n];
    range.popFrontN(n);
    return f;
}

As frontAs(As, R)(R range)
{
    As r;
    (cast(ubyte*)&r)[0..As.sizeof] = range[0..As.sizeof];
    return r;
}

As getFrontAs(As, R)(ref R range)
{
    As r;
    (cast(ubyte*)&r)[0..As.sizeof] = range.getFrontN(As.sizeof)[];
    return r;
}

class MIDIFile
{
    this(const(char)[] filename)
    {
        void[] file = enforce(read(filename), "Couldn't load .midi file!");
        this(cast(ubyte[])file);
    }

    this(const(ubyte)[] buffer)
    {
        if(buffer[0..4] == "RIFF")
        {
            buffer.popFrontN(8);
            assert(buffer[0..4] == "RMID", "Not a midi file...");
            buffer.popFrontN(4);
        }

        MThd_Chunk *pHd = cast(MThd_Chunk*)buffer.ptr;

        assert(pHd.id[] == "MThd", "Not a midi file...");
        bigToHostEndian(pHd);

        format = pHd.format;
        ticksPerBeat = pHd.ticksPerBeat;
        tracks = new MIDIEvent[][pHd.numTracks];

        buffer.popFrontN(8 + pHd.length);

        // we will only deal with type 1 midi files here..
        assert(pHd.format == 1, "Invalid midi type.");

        for(size_t t = 0; t < pHd.numTracks && !buffer.empty; ++t)
        {
            MTrk_Chunk *pTh = cast(MTrk_Chunk*)buffer.ptr;
            bigToHostEndian(pTh);

            buffer.popFrontN(MTrk_Chunk.sizeof);

            if(pTh.id[] == "MTrk")
            {
                const(ubyte)[] track = buffer[0..pTh.length];
                uint tick = 0;
                ubyte lastStatus = 0;

                while(!track.empty)
                {
                    uint delta = readVarLen(track);
                    tick += delta;
                    ubyte status = track.getFront();

                    MIDIEvent ev;
                    bool appendEvent = true;

                    if(status == 0xFF)
                    {
                        // non-midi event
                        MIDIEvents type = cast(MIDIEvents)track.getFront();
                        uint bytes = readVarLen(track);

                        // get the event bytes
                        const(ubyte)[] event = track.getFrontN(bytes);

                        // read event
                        switch(type) with(MIDIEvents)
                        {
                            case MIDIEvents.SequenceNumber:
                                {
                                    static int sequence = 0;

                                    if(!bytes)
                                        ev.sequenceNumber = sequence++;
                                    else
                                    {
                                        ushort seq = event.getFrontAs!ushort;
                                        bigToHostEndian(&seq);
                                        ev.sequenceNumber = cast(int)seq;
                                    }
                                    break;
                                }
                            case Text:
                            case Copyright:
                            case TrackName:
                            case Instrument:
                            case Lyric:
                            case Marker:
                            case CuePoint:
                            case PatchName:
                            case PortName:
                                {
                                    ev.text = (cast(const(char)[])event).idup;
                                    break;
                                }
                            case EndOfTrack:
                                {
                                    // is it valid to have data remaining after the end of track marker?
                                    break;
                                }
                            case Tempo:
                                {
                                    ev.tempo.microsecondsPerBeat = event[0] << 16;
                                    ev.tempo.microsecondsPerBeat |= event[1] << 8;
                                    ev.tempo.microsecondsPerBeat |= event[2];
                                    break;
                                }
                            case SMPTE:
                                {
                                    ev.smpte.hours = event[0];
                                    ev.smpte.minutes = event[1];
                                    ev.smpte.seconds = event[2];
                                    ev.smpte.frames = event[3];
                                    ev.smpte.subFrames = event[4];
                                    break;
                                }
                            case TimeSignature:
                                {
                                    ev.timeSignature.numerator = event[0];
                                    ev.timeSignature.denominator = event[1];
                                    ev.timeSignature.clocks = event[2];
                                    ev.timeSignature.d = event[3];
                                    break;
                                }
                            case KeySignature:
                                {
                                    ev.keySignature.sf = event[0];
                                    ev.keySignature.minor = event[1];
                                    break;
                                }
                            case Custom:
                                {
                                    ev.data = event.idup;
                                    break;
                                }
                            default:
                                // TODO: are there any we missed?
                                appendEvent = false;
                        }

                        if(appendEvent)
                            ev.subType = type;
                    }
                    else if(status == 0xF0)
                    {
                        uint bytes = readVarLen(track);

                        // get the SYSEX bytes
                        const(ubyte)[] event = track.getFrontN(bytes);
                        ev.data = event.idup;
                    }
                    else
                    {
                        if(status < 0x80)
                        {
                            // HACK: stick the last byte we popped back on the front...
                            track = (track.ptr - 1)[0..track.length+1];
                            status = lastStatus;
                        }
                        lastStatus = status;

                        int eventType = status & 0xF0;

                        int param1 = readVarLen(track);
                        int param2 = 0;
                        if(eventType != MIDIEventType.ProgramChange && eventType != MIDIEventType.ChannelAfterTouch)
                            param2 = readVarLen(track);

                        switch(eventType)
                        {
                            case MIDIEventType.NoteOn:
                            case MIDIEventType.NoteOff:
                                {
                                    ev.note.channel = status & 0x0F;
                                    ev.note.note = param1;
                                    ev.note.velocity = param2;
                                    break;
                                }
                            default:
                                // TODO: handle other event types?
                                appendEvent = false;
                        }
                    }

                    // append event to track
                    if(appendEvent)
                    {
                        ev.tick = tick;
                        ev.delta = delta;
                        ev.type = status != 0xFF ? status & 0xF0 : status;
                        if(status != 0xFF)
                            ev.subType = status & 0x0F;

                        tracks[t] ~= ev;
                    }
                }
            }

            buffer.popFrontN(pTh.length);
        }
    }

    int format;
    int ticksPerBeat;

    MIDIEvent[][] tracks;
}

struct MIDIEvent
{
    bool isEvent(MIDIEvents e)
    {
        return type == MIDIEventType.Custom && subType == e;
    }

    struct Note
    {
        ubyte channel;
        int note;
        int velocity;
    }
    struct Tempo
    {
        int microsecondsPerBeat;
    }
    struct SMPTE
    {
        ubyte hours, minutes, seconds, frames, subFrames;
    }
    struct TimeSignature
    {
        ubyte numerator, denominator;
        ubyte clocks;
        ubyte d;
    }
    struct KeySignature
    {
        ubyte sf;
        ubyte minor;
    }

    uint tick;
    uint delta;
    ubyte type;
    ubyte subType;

    union
    {
        Note note;
        int sequenceNumber;
        string text;
        Tempo tempo;
        SMPTE smpte;
        TimeSignature timeSignature;
        KeySignature keySignature;
        immutable(ubyte)[] data;
    }
}

private:

void writeVarLen(ref ubyte[] buffer, uint value)
{
    uint buf;
    buf = value & 0x7F;

    while((value >>= 7))
    {
        buf <<= 8;
        buf |= ((value & 0x7F) | 0x80);
    }

    while(1)
    {
        buffer ~= cast(ubyte)(buf & 0xFF);
        if(buf & 0x80)
            buf >>= 8;
        else
            break;
    }
}

uint readVarLen(ref const(ubyte)[] buffer)
{
    uint value;
    ubyte c;

    value = buffer[0];
    buffer = buffer[1..$];

    if(value & 0x80)
    {
        value &= 0x7F;
        do
        {
            c = buffer[0];
            buffer = buffer[1..$];
            value = (value << 7) + (c & 0x7F);
        }
        while(c & 0x80);
    }

    return value;
}

void flipEndian(T)(T* pData)
{
    static if(is(T == struct))
    {
        foreach(ref m; (*pData).tupleof)
        {
            alias M = typeof(m);
            static if(M.sizeof > 1 && (is(M == struct) || std.traits.isNumeric!M || std.traits.isSomeChar!M))
                flipEndian(&m);
        }
    }
    else
    {
        T copy = *pData;

        ubyte* pBytes = cast(ubyte*)pData;
        const(ubyte)* pCopy = cast(const(ubyte)*)&copy;
        foreach(a; 0 .. T.sizeof)
            pBytes[a] = pCopy[T.sizeof-1-a];
    }
}

version(LittleEndian)
{
    void hostToBigEndian(T)(T* x) { flipEndian(x); }
    void hostToLittleEndian(T)(T* x) {}
    void littleToHostEndian(T)(T* x) {}
    void bigToHostEndian(T)(T* x) { flipEndian(x); }
}
else version(BigEndian)
{
    void hostToBigEndian(T)(T* x) {}
    void hostToLittleEndian(T)(T* x) { flipEndian(x); }
    void littleToHostEndian(T)(T* x) { flipEndian(x); }
    void bigToHostEndian(T)(T* x) {}
}
else
    static assert("Unknown endian!");
