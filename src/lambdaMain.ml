open Lwt
open Lwt_react
open LTerm_widget
open CamomileLibraryDyn.Camomile

(* LibIndex.info contains lazy values, we need a specialized equality. *)
let rec eq l1 l2 = match l1, l2 with
  | [], [] -> true
  | [] , _::_  | _::_ , [] -> false
  | {LibIndex. path = path1 ; name = name1 } :: t1 ,
    {LibIndex. path = path2 ; name = name2 } :: t2 ->
      path1 = path2 && name1 = name2 && eq t1 t2

(** Provide an association LibIndex.kind -> string -> style
   In order to encode styles in [Format.tag]. *)
(* This is absolutely horrible, but I don't know how to do better *)
let get_attr, attr_tbl =
  let bold = LTerm_style.({ none with bold = Some true}) in
  let colindex i = LTerm_style.({ none with foreground = Some (index i)}) in
  let h = Hashtbl.create 11 in
  let attr = function
    | LibIndex.Type -> "Type"
    | Value -> "Value"
    | Exception -> "Exception"
    | Field _  -> "Field"
    | Variant _ -> "Variant"
    | Method _ -> "Method"
    | Module -> "Module"
    | ModuleType -> "ModuleType"
    | Class -> "Class"
    | ClassType -> "ClassType"
    | Keyword -> "Keyword"
  in
  Hashtbl.add h "Type"       @@ colindex 6 ;
  Hashtbl.add h "Value"      @@ bold ;
  Hashtbl.add h "Exception"  @@ colindex 3 ;
  Hashtbl.add h "Field"      @@ colindex 4 ;
  Hashtbl.add h "Variant"    @@ colindex 4 ;
  Hashtbl.add h "Method"     @@ bold ;
  Hashtbl.add h "Module"     @@ colindex 1 ;
  Hashtbl.add h "ModuleType" @@ colindex 1 ;
  Hashtbl.add h "Class"      @@ colindex 5 ;
  Hashtbl.add h "ClassType"  @@ colindex 5 ;
  Hashtbl.add h "Keyword"    @@ colindex 7 ;
  attr, h

(** Create a custom styled text formater. *)
(* Should go into lambda-term at some point. *)
let make_fmt () =
  let style = ref LTerm_style.none in
  let content = ref [||] in
  let get_content () = !content in

  let put s pos len =
    let s = String.sub s pos len in
    content := Array.append !content (LTerm_text.stylise s !style)
  in
  let flush () = () in
  let fmt = Format.make_formatter put flush in

  Format.pp_set_tags fmt true;
  Format.pp_set_formatter_tag_functions fmt {
    Format.
    mark_open_tag =
      (fun a -> style := Hashtbl.find attr_tbl a ; "");
    mark_close_tag =
      (fun _ -> style := LTerm_style.none; "");
    print_open_tag = (fun _ -> ());
    print_close_tag = (fun _ -> ());
  } ;

  get_content, fmt


let colorise opts =
  if not opts.IndexOptions.color then
    LibIndex.Format.no_color
  else
    let f kind fstr fmt =
      let tag = get_attr kind in
      Format.pp_open_tag fmt tag;
      Format.kfprintf
        (fun fmt ->
           Format.pp_close_tag fmt ())
        fmt fstr
    in { LibIndex.Format.f }

(** Format the complete answer and return a styled text. *)
let sprint_answer cols colorise id =
  let get_content, fmt = make_fmt () in
  Format.pp_set_margin fmt cols ;
  let print = Format.fprintf fmt in

  print "@[<hv 4>" ;
  LibIndex.Format.kind ~colorise fmt id;
  print " ";
  LibIndex.Format.path ~short:true ~colorise fmt id;
  begin match id with
    | { LibIndex.ty = None }
    | { LibIndex.kind = LibIndex.Module | LibIndex.ModuleType |
                        LibIndex.Class | LibIndex.ClassType }
      -> ()
    | { LibIndex.ty = Some _ } ->
        print "@ @[<h>" ;
        LibIndex.Format.ty ~colorise fmt id;
        print "@]" ;
  end ;
  if Lazy.force id.LibIndex.doc <> None
  then begin
    print "@\n    " ;
    LibIndex.Format.doc ~colorise fmt id
  end ;
  print "@]" ;
  Format.pp_print_flush fmt () ;
  get_content ()


(** Key Bindings *)

module Bindings = Zed_input.Make (LTerm_key)

let () =
  let open LTerm_read_line in
  let open LTerm_key in
  let edit x = Edit (LTerm_edit.Zed x) in
  bind [{ control = false; meta = false; shift = false; code = Right }]    [edit Next_char];
  bind [{ control = false; meta = false; shift = false; code = Left }]     [edit Prev_char];
  bind [{ control = false; meta = true; shift = false; code = Right }]     [edit Next_word];
  bind [{ control = false; meta = true; shift = false; code = Left }]      [edit Prev_word];
  bind [{ control = false; meta = true; shift = false; code = Backspace }] [edit Kill_prev_word];

  bind [{ control = false; meta = false; shift = false; code = Up }]   [Complete_bar_prev];
  bind [{ control = false; meta = false; shift = false; code = Down }] [Complete_bar_next];

  bind [{ control = false; meta = false; shift = false; code = Enter }] [Complete_bar];
  ()


(** Line editor *)
(* Delicate mix between LTerm_read_line.engine and LTerm_edit.edit *)
(* Should go into lambda-term. *)

let regexp_word =
  let set = UCharInfo.load_property_set `Alphabetic in
  let set = List.fold_left (fun set ch -> USet.add (UChar.of_char ch) set) set ['0'; '1'; '2'; '3'; '4'; '5'; '6'; '7'; '8'; '9'] in
  Zed_re.compile (`Repn(`Set set, 1, None))
let newline = UChar.of_char '\n'


class virtual line_editor = object(self)
  inherit LTerm_widget.t "edit"
  inherit [Zed_rope.t] LTerm_read_line.engine () as super

  method text = Zed_rope.to_string (Zed_edit.text self#edit)

  val mutable style = LTerm_style.none
  val mutable marked_style = LTerm_style.none
  val mutable current_line_style = LTerm_style.none
  method! update_resources =
    let rc = self#resource_class and resources = self#resources in
    style <- LTerm_resources.get_style rc resources;
    marked_style <- LTerm_resources.get_style (rc ^ ".marked") resources;
    current_line_style <- LTerm_resources.get_style (rc ^ ".current-line") resources

  val mutable event = E.never
  val mutable resolver = None

  method! can_focus = true

  initializer
    event <- E.map (fun _ -> self#queue_draw) (Zed_edit.update self#edit [Zed_edit.cursor self#context]);
    self#on_event
      (function
         | LTerm_event.Key key -> begin
             let res =
               match resolver with
               | Some res -> res
               | None -> Bindings.resolver [
                   Bindings.pack (fun x -> x) !LTerm_read_line.bindings;
                   Bindings.pack (List.map (fun x -> LTerm_read_line.Edit x)) !LTerm_edit.bindings]
             in
             match Bindings.resolve key res with
               | Bindings.Accepted actions ->
                   resolver <- None;
                   List.iter self#send_action actions ;
                   true
               | Bindings.Continue res ->
                   resolver <- Some res;
                   true
               | Bindings.Rejected ->
                   if resolver = None then
                     match key with
                       | { control = false; meta = false; shift = false; code = Char ch } ->
                           Zed_edit.insert self#context (Zed_rope.singleton ch);
                           true
                       | _ ->
                           false
                   else begin
                     resolver <- None;
                     false
                   end
           end
         | _ ->
             false)

  method! send_action = function
    | Edit (Zed Newline) -> ()
    | action -> super#send_action action

  val mutable shift = 0
  val mutable start = 0

  method! draw ctx _focused =
    let open LTerm_draw in

    let size = LTerm_draw.size ctx in

    (*** Check that the cursor is displayed ***)

    let line_set = Zed_edit.lines self#edit in
    let cursor_offset = Zed_cursor.get_position (Zed_edit.cursor self#context) in
    let cursor_line = Zed_lines.line_index line_set cursor_offset in
    let cursor_column = cursor_offset - Zed_lines.line_start line_set cursor_line in

    (* Horizontal check *)
    if cursor_column < shift || cursor_column >= shift + size.cols then
      shift <- max 0 (cursor_column - size.cols / 2);

    (* Vertical check *)
    let start_line = Zed_lines.line_index line_set start in
    let start_line =
      if cursor_line < start_line || cursor_line >= start_line + size.rows then begin
        let start_line = max 0 (cursor_line - size.rows / 2) in
        start <- Zed_lines.line_start line_set start_line;
        start_line
      end else
        start_line
    in

    (*** Drawing ***)

    (* Initialises points with the text style and spaces. *)
    fill ctx (UChar.of_char ' ');
    fill_style ctx style;

    (*** Text drawing ***)

    let rec draw_line row col zip =
      if Zed_rope.Zip.at_eos zip then
        draw_eoi (row + 1)
      else
        let char, zip = Zed_rope.Zip.next zip in
        if char = newline then begin
          let row = row + 1 in
          if row < size.rows then begin_line row zip
        end else begin
          if col > size.cols then begin
            let row = row + 1 in
            if row < size.rows then skip_eol row zip
          end else begin
            draw_char ctx row col char;
            draw_line row (col + 1) zip
          end
        end

    and skip_eol row zip =
      if Zed_rope.Zip.at_eos zip then
        draw_eoi (row + 1)
      else
        let char, zip = Zed_rope.Zip.next zip in
        if char = newline then
          begin_line row zip
        else
          skip_eol row zip

    and skip_bol row zip remaining =
      if remaining = 0 then
        draw_line row 0 zip
      else if Zed_rope.Zip.at_eos zip then
        draw_eoi (row + 1)
      else
        let char, zip = Zed_rope.Zip.next zip in
        if char = newline then begin
          let row = row + 1 in
          if row < size.rows then begin_line row zip
        end else
          skip_bol row zip (remaining - 1)

    and begin_line row zip =
      if Zed_rope.Zip.at_eos zip then
        draw_eoi row
      else if shift <> 0 then begin
        skip_bol row zip shift
      end else
        draw_line row 0 zip

    and draw_eoi _row =
      ()
    in

    let text = Zed_edit.text self#edit in

    begin_line 0 (Zed_rope.Zip.make_f text start);

    (* Colorize the current line. *)
    for col = 0 to size.cols - 1 do
      set_style (point ctx (cursor_line - start_line) col) current_line_style
    done;

    (* Colorize the selection if needed *)
    if Zed_edit.get_selection self#edit then begin
      let sel_offset = Zed_cursor.get_position (Zed_edit.mark self#edit) in
      let sel_line = Zed_lines.line_index line_set sel_offset in
      let sel_column = sel_offset - Zed_lines.line_start line_set sel_line in
      let line_a, column_a, line_b, column_b =
        if sel_offset < cursor_offset then
          (sel_line, sel_column, cursor_line, cursor_column)
        else
          (cursor_line, cursor_column, sel_line, sel_column)
      in
      let line_a, column_a =
        if line_a < start_line then
          (start_line, 0)
        else
          (line_a, column_a)
      in
      let line_b, column_b =
        if line_b >= start_line + size.rows then
          (start_line + size.rows - 1, size.cols - 1)
        else
          (line_b, column_b)
      in
      if line_a < start_line + size.rows && line_b >= start_line then begin
        let line_a = line_a - start_line and line_b = line_b - start_line in
        let column_a = column_a and column_b = column_b in
        if line_a = line_b then
          for column = column_a to column_b - 1 do
            set_style (point ctx line_a column) marked_style
          done
        else begin
          for column = column_a to size.cols - 1 do
            set_style (point ctx line_a column) marked_style
          done;
          for line = line_a + 1 to line_b - 1 do
            for column = 0 to size.cols - 1 do
              set_style (point ctx line column) marked_style
            done
          done;
          for column = 0 to column_b - 1 do
            set_style (point ctx line_b column) marked_style
          done
        end
      end
    end

  method! cursor_position =
    let line_set = Zed_edit.lines self#edit in
    let cursor_offset = Zed_cursor.get_position (Zed_edit.cursor self#context) in
    let cursor_line = Zed_lines.line_index line_set cursor_offset in
    let cursor_column = cursor_offset - Zed_lines.line_start line_set cursor_line in
    let start_line = Zed_lines.line_index line_set start in
    Some { row = cursor_line - start_line; col = cursor_column - shift }
end


(** Mono line input with completion for a LibIndex.path. *)
class completion_box options wakener =

  let completion_info, set_completion_info =
    S.create ~eq ([] : LibIndex.info list) in

  object (self)
    inherit line_editor as super

    val size_request = { LTerm_geom. rows = 1; cols = 1 }
    method! size_request = size_request

    method eval = Zed_edit.text self#edit

    method! completion =
      let content = self#eval in
      let response =
        LibIndex.complete
          options.IndexOptions.lib_info
          ~filter:(IndexOptions.filter options)
          (Zed_rope.to_string content)
      in
      set_completion_info response ;
      let completions =
        let is_module = function
          | {LibIndex. kind = Module | ModuleType | Class | ClassType } -> true
          | _ -> false
        in
        List.map
          (fun x ->
             let dot = if is_module x then "." else "" in
             let s = LibIndex.Print.path ~short:true x in
             (s, dot) )
          response
      in
      self#set_completion 0 completions

    method completion_info = completion_info


    method! send_action = function
      (* Exit the app on Break and Interrupt *)
      | action ->
          try super#send_action action
          with Sys.Break | LTerm_read_line.Interrupt -> wakeup wakener ()

  end


(** Count the number of line took by a text. *)
(* Assume there are now overfills, should be ensured by format. *)
let height (str : LTerm_text.t) =
  let last = Array.length str - 1 in
  let count = ref 0 in
  for i = 0 to last do
    if fst str.(i) = newline then incr count
  done ;
  (* Don't count a potential last newline twice *)
  if fst str.(last) <> newline then incr count ;
  !count

(** The show box shows the result of a research.
    Contains a list of entry and the index of the "focused" element in this set of entry.

    Drawing is done by iteration on the entry until the box is filled.
*)
class show_box color = object (self)
  inherit LTerm_widget.t "show_box"

  val mutable content = []
  val mutable index = 0

  method content = content
  method index = index

  method set_content new_content new_index =
    content <- new_content ;
    index <- new_index ;
    self#queue_draw

  method! draw ctx _focused =
    let k = ref 0 in
    List.iteri (fun i info ->
        let open LTerm_geom in
        let text = sprint_answer ((size_of_rect self#allocation).cols - 2) color info in
        let text_height = height text in
        LTerm_draw.draw_styled ctx !k 2 text ;
        if i = index then LTerm_draw.draw_char ctx !k 0 @@ CamomileLibrary.UChar.of_char '>' ;
        k := !k + text_height
      )
      content

end

(** markup styling using styles *)
(* Should go in lambda-term *)

let begin_style ?(cont=[]) style =
  let open LTerm_text in
  let (@+) (x, f) l = match x with
    | Some v -> f v :: l
    | None -> l
  in
  let {LTerm_style. bold ; underline ; blink ; reverse ; foreground ; background } = style in
  (bold, fun x -> B_bold x) @+ (underline, fun x -> B_underline x) @+
  (blink, fun x -> B_blink x) @+ (reverse, fun x -> B_reverse x) @+
  (foreground, fun x -> B_fg x) @+ (background, fun x -> B_bg x) @+
  cont

let end_style ?(cont=[]) style =
  let open LTerm_text in
  let (@+) (x, t) l = match x with
    | Some _ -> t :: l
    | None -> l
  in
  let {LTerm_style. bold ; underline ; blink ; reverse ; foreground ; background } = style in
  (bold, E_bold) @+ (underline, E_underline) @+
  (blink, E_blink) @+ (reverse, E_reverse) @+
  (foreground, E_fg) @+ (background, E_bg) @+
  cont

let enclose_style ?(cont=[]) style markup =
  let end_ = end_style ~cont style in
  let begin_ = begin_style ~cont:(markup @ end_) style in
  begin_

(** Create a styled text with the various kinds. *)
let kinds_to_string options =
  let open LTerm_text in
  let (@+) (c,hash,b) s =
    if b then
      let cont = if s = [] then [S " "] else S ", " :: s in
      enclose_style ~cont (Hashtbl.find attr_tbl hash) [S c]
    else s
  in
  let open IndexOptions in
  let { t ; v ; e ; c ; m ; s ; k } = options.filter in
  let l =
    ("t","Type",t) @+ ("v","Value",v) @+ ("e","Exception",e) @+
    ("c","Variant",c) @+ ("m","Module",m) @+ ("s","ModuleType",s) @+
    ("k","Keyword",k) @+ [] in
  eval (S " kinds: " :: l)

(** A frame with extra info on the border. *)
class frame_info options = object
  inherit frame as super

  method! draw ctx focused =
    super#draw ctx focused ;
    let s = kinds_to_string options in
    let width = (LTerm_draw.size ctx).cols in
    let len = Array.length s in
    if width > len + 2 then
      LTerm_draw.draw_styled ctx 0 (width - len - 1) s
end



(** Express the result as an event mapped on the content of the completion box. *)
let show_completion show_box input =
  let rec drop n k = function
    | _ :: l when n > 0 -> drop (n-1) (k-1) l
    | l -> l, k
  in

  (* For now, we select the line starting from index - 1,
     we could do something more clever. *)
  let select i l = drop (i - 1) i l in
  let eq_pair (l, i) (l', i') = i = i' && eq l l' in

  input#completion_info
  |> S.l2 ~eq:eq_pair select input#completion_index
  |> S.map (fun (l, index) -> show_box#set_content l index)


(** Boilerplate *)

let main options =
  let waiter, wakener = wait () in

  let root = new LTerm_widget.vbox in
  let comp = new frame_info options in
  let input = new completion_box options wakener in
  comp#set input ;
  root#add ~expand:false comp ;

  let show_box = new show_box (colorise options) in
  root#add show_box ;

  S.keep @@ show_completion show_box input ;

  Lazy.force LTerm.stdout >>=
  fun term -> LTerm_widget.run term root waiter

let run options () =
  Lwt_main.run (main options)

let main_term : unit Cmdliner.Term.t * Cmdliner.Term.info =
  let open Cmdliner in
  let doc = "Interactively completes and prints documentation." in
  Term.(pure run $ IndexOptions.common_opts $ pure ()),
  Term.info "ocp-browser" ~doc

let () =
  match Cmdliner.Term.eval main_term
  with
  | `Error _ -> exit 1
  | _ -> exit 0
