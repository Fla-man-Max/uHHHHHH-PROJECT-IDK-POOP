package funkin.modding.psychlua;

#if FEATURE_PSYCH_LUA
import flixel.FlxG;
import flixel.FlxBasic;
import flixel.FlxCamera;
import flixel.FlxSprite;
import flixel.sound.FlxSound;
import flixel.text.FlxText;
import flixel.tweens.FlxTween;
import flixel.util.FlxTimer;
import funkin.Conductor;
import funkin.Preferences;
import funkin.modding.PolymodHandler;
import funkin.modding.events.ScriptEvent;
import funkin.play.PlayState;
import funkin.play.notes.NoteSprite;
import funkin.play.notes.SustainTrail;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
using StringTools;

@:access(funkin.modding.PolymodHandler)
@:access(funkin.play.PlayState)
class PsychLuaHost
{
  public final game:PlayState;
  public final noteOptions:PsychLuaNotes;
  public var scripts(default, null):Array<PsychLuaScript> = [];
  public final objects:Map<String, Dynamic> = [];
  public final variables:Map<String, Dynamic> = [];
  public final owners:Map<String, PsychLuaScript> = [];
  public final containers:Map<String, flixel.FlxState> = [];
  public final tweens:Map<String, FlxTween> = [];
  public final timers:Map<String, FlxTimer> = [];
  public final sounds:Map<String, FlxSound> = [];
  public final tweenOwners:Map<String, PsychLuaScript> = [];
  public final timerOwners:Map<String, PsychLuaScript> = [];
  public final soundOwners:Map<String, PsychLuaScript> = [];
  public var autoReload:Bool = false;
  public var reloadRequested:Bool = false;
  public var cameraTarget:String = 'dad';
  var signatures:Map<String, String> = [];
  var lastReloadAttempt:String = '';
  var scanTimer:Float = 0;
  var disposed:Bool = false;
  var unloading:Bool = false;
  var lastSection:Int = -1;
  var holdSteps:Map<SustainTrail, Int> = [];
  var errorText:FlxText;

  public function new(game:PlayState) { this.game = game; noteOptions = new PsychLuaNotes(this); }

  public function start():Void
  {
    var entries = discover();
    lastReloadAttempt = [for (entry in entries) entry.path + ':' + signature(entry.path)].join('|');
    for (entry in entries) load(entry.path, entry.root);
    call('onCreatePost', []);
  }

  function addDirectory(result:Array<{path:String, root:String}>, root:String, relative:String):Void
  {
    var dir = root + '/' + relative;
    if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir)) return;
    var files = FileSystem.readDirectory(dir);
    files.sort(Reflect.compare);
    for (file in files) if (file.toLowerCase().endsWith('.lua')) addFile(result, root, relative + '/' + file);
  }

  function addFile(result:Array<{path:String, root:String}>, root:String, relative:String):Void
  {
    if (relative.contains('..') || Path.isAbsolute(relative)) return;
    var path = Path.normalize(root + '/' + relative);
    if (!FileSystem.exists(path) || FileSystem.isDirectory(path)) return;
    for (entry in result) if (entry.path == path) return;
    result.push({path: path, root: root});
  }

  public function discover():Array<{path:String, root:String}>
  {
    var result = [];
    for (dir in PolymodHandler.loadedModDirs)
    {
      var root = Path.normalize(PolymodHandler.MOD_FOLDER + '/' + dir);
      if (!FileSystem.exists(root) || !FileSystem.isDirectory(root)) continue;
      root = FileSystem.fullPath(root).replace('\\', '/');
      addDirectory(result, root, 'scripts');
      addDirectory(result, root, 'data/' + game.currentSong.id);
      addDirectory(result, root, 'songs/' + game.currentSong.id);
      addFile(result, root, 'stages/' + game.currentStageId + '.lua');
      if (game.currentStage != null)
        for (character in [game.currentStage.getBoyfriend(), game.currentStage.getDad(), game.currentStage.getGirlfriend()])
          if (character != null) addFile(result, root, 'characters/' + character.characterId + '.lua');
      if (game.currentChart != null)
      {
        var kinds:Map<String, Bool> = [];
        for (note in game.currentChart.notes) if (note.kind != null && note.kind != '') kinds.set(note.kind, true);
        for (kind in kinds.keys()) addFile(result, root, 'custom_notetypes/' + kind + '.lua');
        for (event in game.currentChart.events) addFile(result, root, 'custom_events/' + event.eventKind + '.lua');
      }
    }
    return result;
  }

  public function load(path:String, root:String):Bool
  {
    if (disposed || unloading) return false;
    for (script in scripts) if (script.path == path && !script.closed) return false;
    var script:PsychLuaScript = null;
    try
    {
      var source = File.getContent(path);
      script = new PsychLuaScript(this, path, root);
      if (!script.compile(source)) { script.destroy(); return false; }
      scripts.push(script);
      if (!script.execute(source, 'load'))
      {
        scripts.remove(script);
        script.destroy();
        return false;
      }
      signatures.set(path, signature(path));
      script.call('onCreate', []);
      return true;
    }
    catch (error:haxe.Exception)
    {
      if (script != null) { scripts.remove(script); script.destroy(); }
      report('[$path] ' + error.message);
      return false;
    }
  }

  function signature(path:String):String
  {
    if (!FileSystem.exists(path)) return '';
    var stat = FileSystem.stat(path);
    return stat.mtime.getTime() + ':' + stat.size;
  }

  public function reload():Bool
  {
    var entries = discover();
    lastReloadAttempt = [for (entry in entries) entry.path + ':' + signature(entry.path)].join('|');
    for (entry in entries)
    {
      var probe = new PsychLuaScript(this, entry.path, entry.root);
      var valid = probe.compile(File.getContent(entry.path));
      probe.destroy();
      if (!valid) return false;
    }
    unloading = true;
    for (script in scripts.copy()) script.destroy();
    scripts.resize(0);
    unloading = false;
    holdSteps.clear();
    signatures.clear();
    start();
    call('onReload', []);
    return true;
  }

  public function update(elapsed:Float):Void
  {
    if (disposed) return;
    for (script in scripts.copy()) if (script.closed && script.depth == 0) { script.destroy(); scripts.remove(script); }
    #if desktop
    if (FlxG.keys.pressed.CONTROL && FlxG.keys.pressed.SHIFT && FlxG.keys.justPressed.R) reloadRequested = true;
    #end
    scanTimer += elapsed;
    if (autoReload && scanTimer >= 1)
    {
      scanTimer = 0;
      try
      {
        var entries = discover();
        var fingerprint = [for (entry in entries) entry.path + ':' + signature(entry.path)].join('|');
        if (fingerprint != lastReloadAttempt) reloadRequested = true;
      }
      catch (error:haxe.Exception) report('Auto reload: ' + error.message);
    }
    if (reloadRequested)
    {
      reloadRequested = false;
      try reload() catch (error:haxe.Exception) report('Reload: ' + error.message);
    }
    for (script in scripts) updateGlobals(script);
    call('onUpdate', [elapsed]);
  }

  public function call(name:String, args:Array<Dynamic>, ignoreStops:Bool = false, ?exclude:PsychLuaScript):Dynamic
  {
    var result:Dynamic = PsychLuaScript.CONTINUE;
    for (script in scripts.copy())
    {
      if (script == exclude || script.closed) continue;
      var value = script.call(name, args);
      if (value != PsychLuaScript.CONTINUE) result = value;
      if (!ignoreStops && (value == PsychLuaScript.STOP_LUA || value == PsychLuaScript.STOP_ALL)) break;
    }
    return result;
  }

  public function event(event:ScriptEvent):Void
  {
    if (disposed) return;
    var args:Array<Dynamic> = [];
    var name:String = null;
    switch (event.type)
    {
      case SONG_START: name = 'onSongStart';
      case SONG_END: name = 'onEndSong';
      case PAUSE: name = 'onPause';
      case RESUME: name = 'onResume';
      case COUNTDOWN_START: name = 'onStartCountdown';
      case COUNTDOWN_STEP:
        name = 'onCountdownTick';
        var countdown:CountdownScriptEvent = cast event;
        args = [switch (countdown.step) { case BEFORE: -1; case THREE: 0; case TWO: 1; case ONE: 2; case GO: 3; case AFTER: 4; }];
      case SONG_STEP_HIT: name = 'onStepHit';
      case SONG_BEAT_HIT: name = 'onBeatHit';
      case GAME_OVER: name = 'onGameOver';
      case SONG_RETRY: name = 'onSongRetry'; reloadRequested = true;
      case NOTE_INCOMING, NOTE_HIT, NOTE_MISS:
        var noteEvent:NoteScriptEvent = cast event;
        var note = noteEvent.note;
        if (note == null) return;
        var player = game.playerStrumline.notes.members.contains(note);
        name = event.type == NOTE_INCOMING ? 'onSpawnNote' : event.type == NOTE_MISS ? 'noteMiss' : (player ? 'goodNoteHit' : 'opponentNoteHit');
        args = [notes().indexOf(note), cast(note.direction, Int), note.kind, false];
      case NOTE_HOLD_DROP:
        var drop:HoldNoteScriptEvent = cast event;
        var hold = drop.holdNote;
        if (hold == null) return;
        name = 'noteMiss';
        args = [notes().indexOf(hold), cast(hold.noteDirection, Int), hold.noteData?.kind ?? '', true];
      case NOTE_GHOST_MISS:
        name = 'noteMissPress';
        var ghost:GhostMissNoteScriptEvent = cast event;
        args = [cast(ghost.dir, Int)];
      case SONG_EVENT:
        var songEvent:SongEventScriptEvent = cast event;
        var values:Dynamic = songEvent.eventData.value;
        if (!event.eventCanceled && songEvent.eventData.eventKind == 'FocusCamera')
        {
          var char = songEvent.eventData.getInt('char');
          if (char == null && Std.isOfType(values, Int)) char = cast values;
          cameraTarget = switch (char ?? 0) { case 0: 'boyfriend'; case 1: 'dad'; case 2: 'gf'; default: ''; };
          call('onMoveCamera', [cameraTarget]);
        }
        name = 'onEvent';
        args = [songEvent.eventData.eventKind, values == null ? '' : Reflect.field(values, 'value1'),
          values == null ? '' : Reflect.field(values, 'value2'), songEvent.eventData.time];
      default:
    }
    if (name == null) return;
    for (script in scripts) updateGlobals(script);
    var result = call(name, args);
    if (result == PsychLuaScript.STOP || result == PsychLuaScript.STOP_ALL) event.cancelEvent();
  }

  public function updateGlobals(script:PsychLuaScript):Void
  {
    var conductor = Conductor.instance;
    script.set('curBeat', conductor.currentBeat);
    script.set('curStep', conductor.currentStep);
    script.set('curDecBeat', conductor.currentBeatTime);
    script.set('curDecStep', conductor.currentStepTime);
    script.set('curSection', Std.int(conductor.currentStep / 16));
    script.set('curBpm', conductor.bpm);
    script.set('bpm', conductor.bpm);
    script.set('crochet', conductor.beatLengthMs);
    script.set('stepCrochet', conductor.stepLengthMs);
    script.set('songPosition', conductor.songPosition);
    script.set('songName', game.currentChart?.songName ?? game.currentSong.id);
    script.set('songPath', game.currentSong.id);
    script.set('songLength', FlxG.sound.music?.length ?? 0);
    script.set('curStage', game.currentStageId);
    script.set('screenWidth', FlxG.width);
    script.set('screenHeight', FlxG.height);
    script.set('downscroll', Preferences.downscroll);
    script.set('scrollSpeed', game.currentChart?.scrollSpeed ?? 1);
    script.set('score', game.songScore);
    script.set('health', game.health);
    script.set('difficultyName', game.currentDifficulty);
    script.set('inGameOver', game.isPlayerDying);
    script.set('mustHitSection', cameraTarget == 'boyfriend');
  }

  public function receptors():Array<Dynamic>
  {
    var result:Array<Dynamic> = [];
    if (game.opponentStrumline != null) for (note in game.opponentStrumline.strumlineNotes.members) result.push(note);
    if (game.playerStrumline != null) for (note in game.playerStrumline.strumlineNotes.members) result.push(note);
    return result;
  }

  public function postUpdate(elapsed:Float):Void
  {
    if (disposed) return;
    var section = Std.int(Conductor.instance.currentStep / 16);
    if (section >= 0 && section != lastSection)
    {
      lastSection = section;
      for (script in scripts) updateGlobals(script);
      call('onSectionHit', []);
    }
    for (hold in holdSteps.keys()) if (!hold.alive || hold.missedNote || hold.sustainLength <= 0) holdSteps.remove(hold);
    if (!game.isPlayerDying && !game.isInCutscene)
    {
      for (strumline in [game.opponentStrumline, game.playerStrumline])
      {
        if (strumline == null) continue;
        for (hold in strumline.holdNotes.members)
        {
          if (hold == null || !hold.alive || !hold.hitNote || hold.missedNote || hold.sustainLength <= 0) continue;
          var step = Conductor.instance.currentStep;
          if (holdSteps.get(hold) == step) continue;
          holdSteps.set(hold, step);
          call(strumline == game.playerStrumline ? 'goodNoteHit' : 'opponentNoteHit',
            [notes().indexOf(hold), cast(hold.noteDirection, Int), hold.noteData?.kind ?? '', true]);
        }
      }
    }
    call('onUpdatePost', [elapsed]);
  }

  public function notes():Array<FlxSprite>
  {
    var result:Array<FlxSprite> = [];
    if (game.opponentStrumline != null) for (note in game.opponentStrumline.notes.members) if (note != null && note.alive) result.push(note);
    if (game.playerStrumline != null) for (note in game.playerStrumline.notes.members) if (note != null && note.alive) result.push(note);
    if (game.opponentStrumline != null) for (note in game.opponentStrumline.holdNotes.members) if (note != null && note.alive) result.push(note);
    if (game.playerStrumline != null) for (note in game.playerStrumline.holdNotes.members) if (note != null && note.alive) result.push(note);
    return result;
  }

  public function camera(name:String):FlxCamera
  {
    return switch ((name ?? 'game').toLowerCase())
    {
      case 'hud', 'camhud': game.camHUD;
      case 'other', 'camother': game.camCutscene;
      default: game.camGame;
    };
  }

  public function rootObject(name:String):Dynamic
  {
    if (objects.exists(name)) return objects.get(name);
    if (variables.exists(name)) return variables.get(name);
    return switch (name)
    {
      case 'boyfriend': game.currentStage?.getBoyfriend();
      case 'dad': game.currentStage?.getDad();
      case 'gf': game.currentStage?.getGirlfriend();
      case 'camGame', 'camHUD', 'camOther': camera(name);
      case 'strumLineNotes': {members: receptors(), length: receptors().length};
      case 'playerStrums': game.playerStrumline?.strumlineNotes;
      case 'opponentStrums': game.opponentStrumline?.strumlineNotes;
      case 'notes': {members: notes(), length: notes().length};
      case 'unspawnNotes': game.currentChart?.notes;
      case 'camFollow': game.cameraFollowPoint;
      default: Reflect.getProperty(game, name);
    };
  }

  public function own(tag:String, object:Dynamic, script:PsychLuaScript):Void
  {
    removeObject(tag, true);
    objects.set(tag, object);
    owners.set(tag, script);
  }

  public function removeObject(tag:String, destroy:Bool):Void
  {
    var object = objects.get(tag);
    if (object == null) return;
    var container = containers.get(tag);
    if (container != null) container.remove(cast object, true);
    if (Std.isOfType(object, FlxBasic)) game.remove(cast object, true);
    containers.remove(tag);
    if (destroy)
    {
      objects.remove(tag);
      owners.remove(tag);
      if (Std.isOfType(object, FlxBasic)) cast(object, FlxBasic).destroy();
    }
  }

  public function releaseOwned(script:PsychLuaScript):Void
  {
    for (tag in [for (tag => owner in tweenOwners) if (owner == script) tag])
    { tweens.get(tag)?.cancel(); tweens.remove(tag); tweenOwners.remove(tag); }
    for (tag in [for (tag => owner in timerOwners) if (owner == script) tag])
    { timers.get(tag)?.cancel(); timers.remove(tag); timerOwners.remove(tag); }
    for (tag in [for (tag => owner in soundOwners) if (owner == script) tag])
    { var sound = sounds.get(tag); FlxG.sound.list.remove(sound, true); sound?.destroy(); sounds.remove(tag); soundOwners.remove(tag); }
    for (tag in [for (tag => owner in owners) if (owner == script) tag]) removeObject(tag, true);
  }

  public function report(message:String):Void
  {
    trace('[Psych Lua] ' + message);
    if (disposed) return;
    if (errorText == null)
    {
      errorText = new FlxText(12, 12, FlxG.width - 24, '', 16);
      errorText.cameras = [game.camHUD];
      errorText.scrollFactor.set();
      errorText.color = 0xFFFF6666;
      errorText.borderStyle = OUTLINE;
      errorText.borderColor = 0xFF000000;
      game.add(errorText);
    }
    errorText.text = message;
  }

  public function destroy():Void
  {
    if (disposed) return;
    disposed = true;
    for (script in scripts.copy()) script.destroy();
    scripts.resize(0);
    noteOptions.clear();
    variables.clear();
    holdSteps.clear();
    if (errorText != null) { game.remove(errorText, true); errorText.destroy(); errorText = null; }
  }
}
#end
