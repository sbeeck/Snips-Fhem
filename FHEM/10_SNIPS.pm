
use strict;
use warnings;

my %gets = (
    "version" => "",
    "status" => ""
);

my %sets = (
    "say" => "",
    "play" => ""
);

# MQTT Topics die das Modul automatisch abonniert
my @topics = qw(
    hermes/intent/+
);

sub SNIPS_Initialize($) {
    my $hash = shift @_;

    # Attribute snipsName und snipsRoom für andere Devices zur Verfügung abbestellen
    addToAttrList("snipsName");
    addToAttrList("snipsRoom");
    addToAttrList("snipsMapping:textField-long");

    # Consumer
    $hash->{DefFn} = "SNIPS::Define";
    $hash->{UndefFn} = "SNIPS::Undefine";
    $hash->{SetFn} = "SNIPS::Set";
    $hash->{AttrFn} = "SNIPS::Attr";
    $hash->{AttrList} = "IODev defaultRoom " . $main::readingFnAttributes;
    $hash->{OnMessageFn} = "SNIPS::onmessage";

    main::LoadModule("MQTT");
}

package SNIPS;

use strict;
use warnings;
use POSIX;
use GPUtils qw(:all);
use JSON;
use Net::MQTT::Constants;

BEGIN {
    MQTT->import(qw(:all));

    GP_Import(qw(
        devspec2array
        CommandDeleteReading
        CommandAttr
        readingsSingleUpdate
        readingsBulkUpdate
        readingsBeginUpdate
        readingsEndUpdate
        Log3
        fhem
        defs
        AttrVal
        ReadingsVal
        round
    ))
};


# Device anlegen
sub Define() {
    my ($hash, $def) = @_;
    my @args = split("[ \t]+", $def);

    # Minimale Anzahl der nötigen Argumente vorhanden?
    return "Invalid number of arguments: define <name> SNIPS IODev Prefix" if (int(@args) < 4);

    my ($name, $type, $IODev, $prefix) = @args;
    $hash->{MODULE_VERSION} = "0.1";
    $hash->{helper}{prefix} = $prefix;

    # IODev setzen und als MQTT Client registrieren
    $main::attr{$name}{IODev} = $IODev;
    MQTT::Client_Define($hash, $def);

    # Benötigte MQTT Topics abonnieren
    subscribeTopics($hash);

    return undef;
};


# Device löschen
sub Undefine($$) {
    my ($hash, $name) = @_;

    # MQTT Abonnements löschen
    unsubscribeTopics($hash);

    # Weitere Schritte an das MQTT Modul übergeben, damit man dort als Client ausgetragen wird
    return MQTT::Client_Undefine($hash);
}


# Set Befehl aufgerufen
sub Set($$$@) {
    my ($hash, $name, $command, @values) = @_;
    return "Unknown argument $command, choose one of " . join(" ", sort keys %sets) if(!defined($sets{$command}));

    Log3($hash->{NAME}, 5, "set " . $command . " - value: " . join (" ", @values));

    my $msgid;
    my $retain = $hash->{".retain"}->{'*'};
    my $qos = $hash->{".qos"}->{'*'};

    # Say Befehl
    if ($command eq "say") {
        my $topic = "hermes/path/to/tts";
        my $value = join (" ", @values);

        $msgid = send_publish($hash->{IODev}, topic => $topic, message => $value, qos => $qos, retain => $retain);
        Log3($hash->{NAME}, 5, "sent (tts) '" . $value . "' to " . $topic);
    }

    $hash->{message_ids}->{$msgid}++ if defined $msgid;
}

# Attribute setzen / löschen
sub Attr($$$$) {
    my ($command, $name, $attribute, $value) = @_;
    my $hash = $defs{$name};

    # IODev Attribut gesetzt
    if ($attribute eq "IODev") {

        return undef;
    }

    return undef;
}


# Topics abonnieren
sub subscribeTopics($) {
    my ($hash) = @_;

    foreach (@topics) {
        my ($mqos, $mretain, $mtopic, $mvalue, $mcmd) = MQTT::parsePublishCmdStr($_);
        MQTT::client_subscribe_topic($hash,$mtopic,$mqos,$mretain);

        Log3($hash->{NAME}, 5, "Topic subscribed: " . $_);
    }
}

# Topics abbestellen
sub unsubscribeTopics($) {
    my ($hash) = @_;

    foreach (@topics) {
        my ($mqos, $mretain, $mtopic, $mvalue, $mcmd) = MQTT::parsePublishCmdStr($_);
        MQTT::client_unsubscribe_topic($hash,$mtopic);

        Log3($hash->{NAME}, 5, "Topic unsubscribed: " . $_);
    }
}


# Raum aus gesprochenem Text oder aus siteId verwenden? (siteId "default" durch Attr defaultRoom ersetzen)
sub roomName ($$) {
  my ($hash, $data) = @_;

  my $room;
  my $defaultRoom = AttrVal($hash->{NAME},"defaultRoom","default");

  # Slot "Room" im JSON vorhanden? Sonst Raum des angesprochenen Satelites verwenden
  if (exists($data->{'Room'})) {
      $room = $data->{'Room'};
  } else {
      $room = $data->{'siteId'};
      $room = $defaultRoom if ($room eq 'default' || !(length $room));
  }

  return $room;
}


# Gerät über Raum und Namen suchen
sub getDevice($$$) {
    my ($hash, $room, $name) = @_;
    my $device;
    my $devspec = "room=Snips";
    my @devices = devspec2array($devspec);

    # devspec2array sendet bei keinen Treffern als einziges Ergebnis den devSpec String zurück
    return undef if (@devices == 1 && $devices[0] eq $devspec);

    foreach (@devices) {
        # 2 Arrays bilden mit Namen und Räumen des Devices
        my @names = ($_, AttrVal($_,"alias",undef), AttrVal($_,"snipsName",undef));
        my @rooms = split(',', AttrVal($_,"room",undef));
        push (@rooms, AttrVal($_,"snipsRoom",undef));

        # Case Insensitive schauen ob der gesuchte Name (oder besser Name und Raum) in den Arrays vorhanden ist
        if (grep( /^$name$/i, @names)) {
            if (!defined($device) || grep( /^$room$/i, @rooms)) {
                $device = $_;
            }
        }
    }
    return $device;
}


# snipsMapping parsen und gefundene Settings zurückliefern
sub getMapping($$$$) {
    my ($hash, $device, $intent, $type) = @_;
    my @mappings, my $mapping;
    my $mappingsString = AttrVal($device,"snipsMapping",undef);

    # String in einzelne Mappings teilen
    @mappings = split(/\n/, $mappingsString);

    foreach (@mappings) {
        # Nur Mappings vom gesuchten Typ verwenden
        next unless $_ =~ qr/^$intent/;
        my %hash = split(/[,=]/, $_);
        if (!defined($mapping) || (defined($type) && $hash{'type'} eq $type)) {
            $mapping = \%hash;

            Log3($hash->{NAME}, 5, "snipsMapping selected: $_");
        }
    }

    return $mapping;
}


# JSON parsen
sub parseJSON($$$) {
    my ($hash, $intent, $json) = @_;
    my $data;

    # JSON Decode und Fehlerüberprüfung
    my $decoded = eval { decode_json($json) };
    if ($@) {
          return undef;
    }

    # Standard-Keys auslesen
    $data->{'probability'} = $decoded->{'intent'}{'probability'};
    $data->{'sessionId'} = $decoded->{'sessionId'};
    $data->{'siteId'} = $decoded->{'siteId'};

    # Überprüfen ob Slot Array existiert
    if (ref($decoded->{'slots'}) eq 'ARRAY') {
        my @slots = @{$decoded->{'slots'}};

        # Key -> Value Paare aus dem Slot Array ziehen
        foreach my $slot (@slots) {
            my $slotName = $slot->{'slotName'};
            my $slotValue = $slot->{'value'}{'value'};

            $data->{$slotName} = $slotValue;
        }
    }
    return $data;
}


# HashRef zu JSON ecnoden
sub encodeJSON($) {
    my ($hashRef) = @_;
    my $json;

    # JSON Encode und Fehlerüberprüfung
    my $json = eval { encode_json($hashRef) };
    if ($@) {
          return undef;
    }

    return $json;
}


# Empfangene Daten vom MQTT Modul
sub onmessage($$$) {
    my ($hash, $topic, $message) = @_;
    my $prefix = $hash->{helper}{prefix};

    Log3($hash->{NAME}, 5, "received message '" . $message . "' for topic: " . $topic);

    # Readings updaten
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "lastIntentTopic", $topic);
    readingsBulkUpdate($hash, "lastIntentPayload", $message);
    readingsEndUpdate($hash, 1);

    # hermes/intent published
    if ($topic =~ qr/^hermes\/intent\/$prefix:/) {
        # MQTT Pfad und Prefix vom Topic entfernen
        (my $intent = $topic) =~ s/^hermes\/intent\/$prefix://;
        Log3($hash->{NAME}, 5, "Intent: $intent");

        # JSON parsen
        my $data = SNIPS::parseJSON($hash, $intent, $message);

        if ($intent eq 'SetOnOff') {
            SNIPS::handleIntentSetOnOff($hash, $data);
        } elsif ($intent eq 'SetNumeric') {
            SNIPS::handleIntentSetNumeric($hash, $data);
        }
    }
}


# Eingehende "SetOnOff" Intents bearbeiten
sub handleIntentSetOnOff($$) {
    my ($hash, $data) = @_;
    my $value, my $device, my $room;
    my $deviceName;
    my $sendData, my $json;
    my $response = "Da ging etwas schief.";

    Log3($hash->{NAME}, 5, "handleIntentSetOnOff called");

    if (exists($data->{'Device'}) && exists($data->{'Value'})) {
        $room = roomName($hash, $data);
        $value = ($data->{'Value'} eq 'an') ? "on" : "off";
        $device = getDevice($hash, $room, $data->{'Device'});

        Log3($hash->{NAME}, 5, "SetOnOff-Intent: " . $room . " " . $device . " " . $value);

        if (defined($device)) {
            # Gerät schalten
            fhem("set $device $value");
        }
    }
    # Antwort erstellen und Senden
    $sendData =  {
        sessionId => $data->{sessionId},
        text => "ok"
    };

    $json = SNIPS::encodeJSON($sendData);
    MQTT::send_publish($hash->{IODev}, topic => 'hermes/dialogueManager/endSession', message => $json, qos => 0, retain => "0");
}


# Eingehende "SetNumeric" Intents bearbeiten
sub handleIntentSetNumeric($$) {
    my ($hash, $data) = @_;
    my $value, my $device, my $room, my $change, my $type, my $unit;
    my $mapping;
    my $sendData, my $json;
    my $validData = 0;
    my $response = "Da ging etwas schief.";

    Log3($hash->{NAME}, 5, "handleIntentSetNumeric called");

    # Mindestens Device und Value angegeben -> Valid (z.B. Deckenlampe auf 20%)
    $validData = 1 if (exists($data->{'Device'}) && exists($data->{'Value'}));
    # Mindestens Device und Change angegeben -> Valid (z.B. Radio lauter)
    $validData = 1 if (exists($data->{'Device'}) && exists($data->{'Change'}));

    if ($validData == 1) {
        $type = $data->{'Unit'};
        $type = $data->{'Type'};
        $value = $data->{'Value'};
        $change = $data->{'Change'};
        $room = roomName($hash, $data);
        $device = getDevice($hash, $room, $data->{'Device'});
        $mapping = getMapping($hash, $device, "SetNumeric", $type);

        Log3($hash->{NAME}, 5, "SetNumeric-Intent: " . $room . " " . $device . " " . $value . " " . $change . " " . $type);

        # Mapping und Gerät gefunden -> Befehl ausführen
        if (defined($device) && defined($mapping) && defined($mapping->{'cmd'})) {
            my $cmd     = $mapping->{'cmd'};
            my $reading = $mapping->{'SetNumeric'};
            my $minVal  = (defined($mapping->{'minVal'})) ? $mapping->{'minVal'} : 0; # Snips kann keine negativen Nummern bisher, daher erzwungener minVal
            my $maxVal  = (defined($mapping->{'maxVal'})) ? $mapping->{'maxVal'} : undef;
            my $oldVal  = ReadingsVal($device, $reading, 0);
            my $diff    = (defined($value)) ? $value : ((defined($mapping->{'step'})) ? $mapping->{'step'} : 10);
            my $up      = (defined($change) && ($change =~ m/^(rauf|heller|lauter)$/)) ? 1 : 0;
            my $isPercent = (defined($mapping->{'map'}) && lc($mapping->{'map'}) eq "limits") ? 1 : 0;

            # Neuen Stellwert bestimmen
            my $newVal;

            # Direkter Stellwert
            if (defined($value) && !defined($change) && !$isPercent) {
                $newVal = $value;
                # Begrenzung auf evtl. gesetzte min/max Werte
                $newVal = $minVal if (defined($minVal) && $newVal < $minVal);
                $newVal = $maxVal if (defined($maxVal) && $newVal > $maxVal);
                $response = "Ok";
            }
            # Direkter Stellwert als Prozent
            elsif (defined($value) && !defined($change) && $isPercent && defined($minVal) && defined($maxVal)) {
                # Wert von Prozent in Raw-Wert umrechnen
                $newVal = $value;
                $newVal =   0 if ($newVal <   0);
                $newVal = 100 if ($newVal > 100);
                $newVal = main::round(($newVal * (($maxVal - $minVal) / 100)) + $minVal), 0);
                $response = "Ok";
            }
            # Stellwert um Wert x ändern
            elsif (defined($change) && !$isPercent) {
                $newVal = ($up) ? $oldVal + $diff : $oldVal - $diff;
                $newVal = $minVal if (defined($minVal) && $newVal < $minVal);
                $newVal = $maxVal if (defined($maxVal) && $newVal > $maxVal);
                $response = "Ok";
            }
            # Stellwert um Prozent x ändern
            elsif (defined($change) && $isPercent && defined($minVal) && defined($maxVal)) {
                my $diffRaw = main::round(($diff * (($maxVal - $minVal) / 100)) + $minVal), 0);
                $newVal = ($up) ? $oldVal + $diffRaw : $oldVal - $diffRaw
                $newVal = $minVal if ($newVal < $minVal);
                $newVal = $maxVal if ($newVal > $maxVal);
                $response = "Ok";
            }

            # Stellwert senden
            fhem("set $device $cmd $newVal") if defined($newVal);
        }
    }
    # Antwort erstellen
    $sendData =  {
        sessionId => $data->{sessionId},
        text => $response
    };

    $json = SNIPS::encodeJSON($sendData);
    MQTT::send_publish($hash->{IODev}, topic => 'hermes/dialogueManager/endSession', message => $json, qos => 0, retain => "0");
}


# Neuen Sollwert berechnen
sub desiredValue($$$$$$) {
    my ($value, $oldValue, $diff, $minVal, $maxVal, $mapValue) = @_;

    if ($mapValue == 1) {
        # Werte im min/max Bereich

    } else {
        # Kein Mapping, nur Begrenzung auf min/max Werte
        $value = $minVal if (defined($minVal) && $value < $minVal);
        $value = $maxVal if (defined($maxVal) && $value > $maxVal);
    }
}

1;
