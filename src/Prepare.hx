package ;

using tink.CoreApi;

using sys.FileSystem;
using sys.io.File;
using haxe.io.Path;
using Lambda;
using StringTools;
using haxe.Json;

import haxe.io.*;
import haxe.zip.Entry;
import haxe.zip.Writer;
import Sys.*;

abstract Command(Array<String>) from Array<String> {
  public var name(get, never):String;
  inline function get_name() return this[0];

  public function run()
    return new sys.io.Process(this[0], this.slice(1));

  public function exec()
    return Sys.command(this[0], this.slice(1));

  @:from static function ofString(s:String):Command
    return s.split(' ');
}

class Prepare {
  static var START = '<!-- START INDEX -->';
  static var END = '<!-- END INDEX -->';
  static var README = 'README.md';
  static var EXTRAS = 'extraParams.hxml';

  static var INFO = 'haxelib.json';

  static var loadedFiles = new Map();
  static function load(name:String) {
    if (loadedFiles.exists(name))
      return loadedFiles[name];
    return loadedFiles[name] = name.getContent();
  }

  static function exec(cmd:Command, ?exitOnError = true)
    switch cmd.exec() {
      case 0:
      default:
        if (exitOnError) quit('error while running '+cmd.name);
    }

  static function run(cmd:Command) {
    var p = cmd.run();
    return
      switch p.exitCode() {
        case 0:
          Success(p.stdout.readAll());
        case v:
          Failure({ code: v, msg: p.stderr.readAll() });
      }
  }

  static function quit(reason:String):Dynamic {
    println(reason);
    exit(500);
    return null;
  }

  static function ask(data:String, ?options:Array<String>) {
    println('');
    println('Specify $data.');
    if (options == null)
      options = [];
    var i = 0;
    if (options.length > 1)
      for (o in options)
        println('[${++i}] $o');
    var s = null;
    while (true) {
      if (options.length == 1)
        print('$data (${options[0]}):');
      else
        print('$data: ');

      s =
        try
          stdin().readLine()
        catch (e:Dynamic)
          quit(Std.string(e));

      switch Std.parseInt(s) {
        case null:
          if (s != '') return s;
          else if (options.length == 1) return options[0];
        case v:
          if (Std.string(v) != s)
            return s;
          v -= 1;
          if (options[v] == null)
            println('Invalid option $s');
          else
            return options[v];
      }
    }
  }

  static function confirm(s:String) {
    println(s + ' (Y)es/(N)o/(C)ancel');
    while (true)
      switch String.fromCharCode(getChar(true)).toLowerCase() {
        case 'c': quit('Aborted');
        case 'y': return true;
        case 'n': return false;
        default:
      }
  }

  static function main() {
    var args = args();
    #if interp
    setCwd(args.pop());
    #end
    var library = switch args.shift() {
      case null: '.';
      case v: v;
    }

    setCwd(library);

    var info:{
      name: String,
      releasenote: String,
      version: String,
      classPath: String,
    } = load(INFO).parse();

    println('Library ${info.name}');
    println('Last version: ${info.version} (${info.releasenote})');
    println('');
    println('Checking git status ...');

    switch run('git status --porcelain -uno').sure().toString().split(',') {
      case ['']:
        println('... everything committed!');
      case files:
        quit(['You have uncommitted files:'].concat(files).join('\n'));
    }

    println('');
    println('Checking remote status ...');

    var remote = run('git ls-remote origin -h HEAD').sure().toString().substr(0, 40);

    switch run('git --no-pager log -n1 $remote --format=%H') {
      case Failure({ msg: _.toString() => message }):

        if (message.startsWith('fatal: bad object $remote'))
          quit('Pull remote changes first!');
        else
          quit(message);
      default:
        println('... everything up to date!');
    }

    var since =
      switch run('git tag').sure().toString().split('\n') {
        case ['']:
          println('No tags found yet\n');
          '';
        case tags:
          tags.pop();
          tags.reverse();
          var tag = tags[0];
          println('Last tag: $tag\n');
          '$tag..HEAD ';
      }

    var commits =
      switch run('git --no-pager log -n 20 $since--format=%s').sure().toString().split('\n') {
        case []:
          quit('no changes found');
        case v: v.pop(); v;
      }

    do {
      info.version = ask('version', [info.version]);
      info.releasenote = ask('release note', commits);
      println('');
      println(info.stringify('  '));
      println('');
    } while (!confirm('Are these settings alright?'));

    var last = 1;
    function prefix(count:Int)
      return [for (i in 0...count) '\t'].join('')+'- ';

    var content =
      try load(README)
      catch (e:Dynamic) null;

    if (content != null) switch content.split(END) {
      case [pre, body]:
        var out = [pre.split(START)[0] + START];

        for (line in body.split('\n')) {
          line = line.trim();
          var level = 0;
          while (line.charAt(level) == '#') level++;

          if (level > 0) {
            for (extra in last...level-1)
              out.push(prefix(extra));
            var title = line.substr(level).trim();
            var link = title.replace(' ', '-').toLowerCase();
            out.push(prefix(level-1) + '[$title](#$link)');
            last = level;
          }

        }
        out.push('');
        out.push(END + body);

        README.saveContent(out.join('\n'));

      default:
        // quit('missing $START');
    }

    INFO.saveContent(info.stringify('\t'));

    var bundle = '../bundle.zip';

    if (bundle.exists())
      bundle.deleteFile();

    println('Making Bundle');

    var a = new Archive();
    a.add(INFO);
    a.add(README);
    a.add(info.classPath);
    if (EXTRAS.exists())
      a.add(EXTRAS);
    bundle.saveBytes(a.getAll());

    exec(['git', 'commit', '-a', '-m', 'Release ${info.version}'], false);
    exec('git tag ${info.version}');


    println('Local Install');

    exec('haxelib local $bundle');

    println('Pushing');

    exec('git push origin master --tags');


    if (confirm('Submit to haxelib?')) {
      println('Submitting to haxelib');
      exec('haxelib submit $bundle');
    }

    println('Cleanup');

    bundle.deleteFile();
  }
}

abstract Archive(List<Entry>) {
  public function new()
    this = new List();

  public function add(path:String)
    if (path.isDirectory())
      for (file in path.readDirectory())
        add('$path/$file');
    else {
      var blob = path.getBytes();
      this.push({
        fileName: path,
        fileSize : blob.length,
        fileTime : path.stat().mtime,
        compressed : false,
        dataSize : blob.length,
        data : blob,
        crc32: null,//TODO: consider calculating this one
      });
    }

  public function getAll():Bytes {
    var o = new BytesOutput();
    write(o);
    return o.getBytes();
  }

  public function write(o:Output) {
    var w = new Writer(o);
    w.write(this);
  }
}
