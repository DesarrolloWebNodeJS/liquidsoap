(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2019 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA

 *****************************************************************************)

(** Configuration entries *)

module Conf = Dtools.Conf

let conf =
  Conf.void
    ~p:(Configure.conf#plug "frame")
    "Frame format"
    ~comments:
      [
        "Settings for the data representation in frames, which are the";
        "elementary packets of which streams are made.";
      ]

let conf_duration =
  Conf.float ~p:(conf#plug "duration") ~d:0.04
    "Tentative frame duration in seconds"
    ~comments:
      [
        "Audio samplerate and video frame rate constrain the possible frame \
         durations.";
        "This setting is used as a hint for the duration, when \
         'frame.audio.size'";
        "is not provided.";
        "Tweaking frame duration is tricky but needed when dealing with latency";
        "or getting soundcard I/O correctly synchronized with liquidsoap.";
      ]

(* Audio *)
let conf_audio = Conf.void ~p:(conf#plug "audio") "Audio (PCM) format"

let conf_audio_samplerate =
  Conf.int ~p:(conf_audio#plug "samplerate") ~d:44100 "Samplerate"

let conf_audio_channels =
  Conf.int ~p:(conf_audio#plug "channels") ~d:2 "Default number of channels"

let conf_audio_size =
  Conf.int ~p:(conf_audio#plug "size")
    "Tentative frame duration in audio samples"
    ~comments:
      [
        "Audio samplerate and video frame rate constrain the possible frame \
         durations.";
        "This setting is used as a hint for the duration, overriding";
        "'frame.duration'.";
        "Tweaking frame duration is tricky but needed when dealing with latency";
        "or getting soundcard I/O correctly synchronized with liquidsoap.";
      ]

(* Video *)
let conf_video = Conf.void ~p:(conf#plug "video") "Video format"

let conf_video_framerate =
  Conf.int ~p:(conf_video#plug "framerate") ~d:25 "Frame rate"

let conf_video_channels =
  Conf.int ~p:(conf_video#plug "channels") ~d:0 "Default number of channels"

let conf_video_width =
  Conf.int ~p:(conf_video#plug "width") ~d:1280 "Image width"

let conf_video_height =
  Conf.int ~p:(conf_video#plug "height") ~d:720 "Image height"

(* MIDI *)
let conf_midi = Conf.void ~p:(conf#plug "midi") "MIDI parameters"

let conf_midi_channels =
  Conf.int ~p:(conf_midi#plug "channels") ~d:0 "Default number of channels"

(** Format parameters *)

(* The user can set some parameters in the initial configuration script.
 * Once we start working with them, changing them again is dangerous.
 * Since Dtools doesn't allow that, below is a trick to read the settings
 * only once. Later changes will never be taken into account. *)

(* This variable prevents forcing the value of a lazy configuration
 * item before the user gets a chance to override the default. *)
let lazy_config_eval = ref false
let allow_lazy_config_eval () = lazy_config_eval := true
let delayed f = lazy (f ())

let delayed_conf x =
  delayed (fun () ->
      assert !lazy_config_eval;
      x#get)

let ( !! ) = Lazy.force

(** The channel numbers are only defaults, used when channel numbers
  * cannot be inferred / are not forced from the context.
  * I'm currently unsure how much they are really useful. *)

let audio_channels = delayed_conf conf_audio_channels
let video_channels = delayed_conf conf_video_channels
let midi_channels = delayed_conf conf_midi_channels
let video_width = delayed_conf conf_video_width
let video_height = delayed_conf conf_video_height
let audio_rate = delayed_conf conf_audio_samplerate
let video_rate = delayed_conf conf_video_framerate

(* TODO: midi rate is assumed to be the same as audio,
 *   so we should not have two different values *)
let midi_rate = delayed_conf conf_audio_samplerate

(** Greatest common divisor. *)
let rec gcd a b =
  match compare a b with
    | 0 (* a=b *) -> a
    | 1 (* a>b *) -> gcd (a - b) b
    | _ (* a<b *) -> gcd a (b - a)

(** Least common multiplier. *)
let lcm a b = a / gcd a b * b

(* divide early to avoid overflow *)

(** [upper_multiple k m] is the least multiple of [k] that is [>=m]. *)
let upper_multiple k m = if m mod k = 0 then m else (1 + (m / k)) * k

(** The master clock is the slowest possible that can convert to both
  * the audio and video clocks. *)
let master_rate = delayed (fun () -> lcm !!audio_rate !!video_rate)

(** Precompute those ratios to avoid too large integers below. *)
let m_o_a = delayed (fun () -> !!master_rate / !!audio_rate)

let m_o_v = delayed (fun () -> !!master_rate / !!video_rate)
let master_of_audio a = a * !!m_o_a
let master_of_video v = v * !!m_o_v

(* TODO: for now MIDI rate is the same as audio rate. *)
let master_of_midi = master_of_audio
let audio_of_master m = m / !!m_o_a
let video_of_master m = m / !!m_o_v

(* TODO: for now MIDI rate is the same as audio rate. *)
let midi_of_master = audio_of_master
let master_of_seconds d = int_of_float (d *. float !!master_rate)
let audio_of_seconds d = int_of_float (d *. float !!audio_rate)
let video_of_seconds d = int_of_float (d *. float !!video_rate)
let seconds_of_master d = float d /. float !!master_rate
let seconds_of_audio d = float d /. float !!audio_rate
let seconds_of_video d = float d /. float !!video_rate
let log = Log.make ["frame"]

(** The frame size (in master ticks) should allow for an integer
  * number of samples of all types (audio, video).
  * With audio@44100Hz and video@25Hz, ticks=samples and one video
  * sample takes 1764 ticks: we need frames of size N*1764. *)
let size =
  delayed (fun () ->
      let audio = !!audio_rate in
      let video = !!video_rate in
      let master = !!master_rate in
      let granularity = lcm (master / audio) (master / video) in
      let target =
        log#important "Using %dHz audio, %dHz video, %dHz master." audio video
          master;
        log#important
          "Frame size must be a multiple of %d ticks = %d audio samples = %d \
           video samples."
          granularity
          (audio_of_master granularity)
          (video_of_master granularity);
        try
          let d = conf_audio_size#get in
          log#important
            "Targetting 'frame.audio.size': %d audio samples = %d ticks." d
            (master_of_audio d);
          master_of_audio d
        with Conf.Undefined _ ->
          log#important
            "Targetting 'frame.duration': %.2fs = %d audio samples = %d ticks."
            conf_duration#get
            (audio_of_seconds conf_duration#get)
            (master_of_seconds conf_duration#get);
          master_of_seconds conf_duration#get
      in
      let s = upper_multiple granularity (max 1 target) in
      log#important
        "Frames last %.2fs = %d audio samples = %d video samples = %d ticks."
        (seconds_of_master s) (audio_of_master s) (video_of_master s) s;
      s)

let duration = delayed (fun () -> float !!size /. float !!master_rate)

(** Data types *)

type ('a, 'b, 'c) fields = { audio : 'a; video : 'b; midi : 'c }
type multiplicity = Fixed of int | At_least of int

(** High-level, abstract and imprecise stream content type.
  * This controls a changing content type.
  * Currently there is no fine-grained control of the audio and
  * video sample rates and sizes, they are global. *)
type content_kind = (multiplicity, multiplicity, multiplicity) fields

(** Precise description of the channel types for the current track. *)
type content_type = (int, int, int) fields

type content = (audio_t array, video_t array, midi_t array) fields

and audio_t = Audio.Mono.buffer

and video_t = Video.t

and midi_t = MIDI.buffer

(** Compatibilities between content kinds, types and values.
  * [sub a b] if [a] is more permissive than [b]..
  * TODO this is the other way around... it's correct in Lang, phew! *)

let type_of_content c =
  {
    audio = Array.length c.audio;
    video = Array.length c.video;
    midi = Array.length c.midi;
  }

let mul_of_int n = Fixed n

let succ_mul = function
  | Fixed n -> Fixed (n + 1)
  | At_least n -> At_least (n + 1)

let string_of_mul = function
  | Fixed n -> string_of_int n
  | At_least n -> string_of_int n ^ "+"

let string_of_content_kind k =
  Printf.sprintf "{audio=%s;video=%s;midi=%s}" (string_of_mul k.audio)
    (string_of_mul k.video) (string_of_mul k.midi)

let string_of_content_type k =
  Printf.sprintf "{audio=%d;video=%d;midi=%d}" k.audio k.video k.midi

(* Frames *)

(** A metadata is just a mutable hash table.
  * It might be a good idea to straighten that up in the future. *)
type metadata = (string, string) Hashtbl.t

type t = {
  (* Presentation time, in multiple of frame size. *)
  mutable pts : int64;
  (* End of track markers.
   * A break at the end of the buffer is not an end of track.
   * So maybe we should rather call that an end-of-fill marker,
   * and notice that end-of-fills in the middle of a buffer are
   * end-of-tracks.
   * If needed, the end-of-track needs to be put at the beginning of
   * the next frame. *)
  mutable breaks : int list;
  (* Metadata can be put anywhere in the stream. *)
  mutable metadata : (int * metadata) list;
  mutable content : content;
}

(** Create a content chunk. All chunks have the same size. *)
let create_content ctype =
  {
    audio =
      Array.init ctype.audio (fun _ ->
          Audio.Mono.create (audio_of_master !!size));
    video =
      Array.init ctype.video (fun _ ->
          Video.make (video_of_master !!size) !!video_width !!video_height);
    midi = Array.init ctype.midi (fun _ -> MIDI.create (midi_of_master !!size));
  }

let create ctype =
  { pts = 0L; breaks = []; metadata = []; content = create_content ctype }

let dummy =
  {
    pts = 0L;
    breaks = [];
    metadata = [];
    content = { audio = [||]; video = [||]; midi = [||] };
  }

let content_type { content } =
  let { audio; video; midi } = content in
  {
    audio = Array.length audio;
    video = Array.length video;
    midi = Array.length midi;
  }

let audio { content; _ } = content.audio
let set_audio frame audio = frame.content <- { frame.content with audio }
let video { content; _ } = content.video
let set_video frame video = frame.content <- { frame.content with video }
let midi { content; _ } = content.midi
let set_midi frame midi = frame.content <- { frame.content with midi }

(** Content independent *)

let position b = match b.breaks with [] -> 0 | a :: _ -> a
let is_partial b = position b < !!size
let breaks b = b.breaks
let set_breaks b breaks = b.breaks <- breaks
let add_break b br = b.breaks <- br :: b.breaks

let clear (b : t) =
  b.breaks <- [];
  b.metadata <- []

let clear_from (b : t) pos =
  b.breaks <- List.filter (fun p -> p <= pos) b.breaks;
  b.metadata <- List.filter (fun (p, _) -> p <= pos) b.metadata

(* Same as clear but leaves the last metadata at position -1. *)
let advance b =
  b.pts <- Int64.succ b.pts;
  b.breaks <- [];
  let max a (p, m) =
    match a with Some (pa, _) when pa > p -> a | _ -> Some (p, m)
  in
  let rec last a = function [] -> a | b :: l -> last (max a b) l in
  b.metadata <-
    (match last None b.metadata with None -> [] | Some (_, e) -> [(-1, e)])

(** Presentation time stuff. *)

let pts { pts } = pts
let set_pts frame pts = frame.pts <- pts

(** Metadata stuff *)

exception No_metadata

let set_metadata b t m = b.metadata <- (t, m) :: b.metadata

let get_metadata b t =
  try Some (List.assoc t b.metadata) with Not_found -> None

let free_metadata b t =
  b.metadata <- List.filter (fun (tt, _) -> t <> tt) b.metadata

let free_all_metadata b = b.metadata <- []

let get_all_metadata b =
  List.sort
    (fun (x, _) (y, _) -> compare x y)
    (List.filter (fun (x, _) -> x <> -1) b.metadata)

let set_all_metadata b l = b.metadata <- l

let get_past_metadata b =
  try Some (List.assoc (-1) b.metadata) with Not_found -> None

let blit_content src src_pos dst dst_pos len =
  Array.iter2
    (fun a a' ->
      if a != a' then (
        let ( ! ) = audio_of_master in
        Audio.Mono.blit
          (Audio.Mono.sub a !src_pos !len)
          (Audio.Mono.sub a' !dst_pos !len) ))
    src.audio dst.audio;
  Array.iter2
    (fun v v' ->
      if v != v' then (
        let ( ! ) = video_of_master in
        Video.blit v !src_pos v' !dst_pos !len ))
    src.video dst.video;
  Array.iter2
    (fun m m' ->
      if m != m' then (
        let ( ! ) = midi_of_master in
        MIDI.blit m !src_pos m' !dst_pos !len ))
    src.midi dst.midi

(** Copy data from [src] to [dst].
  * This triggers changes of contents layout if needed. *)
let blit src src_pos dst dst_pos len =
  (* Assuming that the tracks have the same track layout,
   * copy a chunk of data from [src] to [dst]. *)
  blit_content src.content src_pos dst.content dst_pos len

(** Raised by [get_chunk] when no chunk is available. *)
exception No_chunk

(** [get_chunk dst src] gets the (end of) next chunk from [src]
  * (a chunk is a region of a frame between two breaks).
  * Metadata relevant to the copied chunk is copied as well,
  * and content layout is changed if needed. *)
let get_chunk ab from =
  assert (is_partial ab);
  let p = position ab in
  let copy_chunk i =
    add_break ab i;
    blit from p ab p (i - p);

    (* If the last metadata before [p] differ in [from] and [ab],
     * copy the one from [from] to [p] in [ab].
     * Note: equality probably does not make much sense for hash tables,
     * but even physical equality should work here, it seems.. *)
    begin
      let before_p l =
        match
          List.sort
            (fun (a, _) (b, _) -> compare b a) (* the greatest *)
            (List.filter (fun x -> fst x < p) l)
          (* that is less than p *)
        with
          | [] -> None
          | x :: _ -> Some (snd x)
      in
      match (before_p from.metadata, before_p ab.metadata) with
        | Some b, a -> if a <> Some b then set_metadata ab p b
        | None, _ -> ()
    end;

    (* Copy new metadata blocks for this chunk.
     * We exclude blocks at the end of chunk, leaving them to be copied
     * during the next get_chunk. *)
    List.iter
      (fun (mp, m) -> if p <= mp && mp < i then set_metadata ab mp m)
      from.metadata
  in
  let rec aux foffset f =
    (* We always have p >= foffset *)
    match f with
      | [] -> raise No_chunk
      | i :: tl ->
          (* Breaks are between ticks, they do range from 0 to size. *)
          assert (0 <= i && i <= !!size);
          if i = 0 && ab.breaks = [] then
            (* The only empty track that we copy,
             * trying to copy empty tracks in the middle could be useful
             * for packets like those forged by add, with a fake first break,
             * but isn't needed (yet) and is painful to implement. *)
            copy_chunk 0
          else if foffset <= p && i > p then copy_chunk i
          else aux i tl
  in
  aux 0 (List.rev from.breaks)

let copy content =
  {
    audio = Array.map Audio.Mono.copy content.audio;
    video = Array.map Video.copy content.video;
    midi = Array.map MIDI.copy content.midi;
  }
