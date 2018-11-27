open Base
open Ppxlib

let digest x =
  Caml.Digest.to_hex (Caml.Digest.string (Caml.Marshal.to_string x []))

let string_of_expression e =
  let buf = Buffer.create 251 in
  Pprintast.expression (Caml.Format.formatter_of_buffer buf) e ;
  Buffer.contents buf

let new_id =
  let c = ref 0 in
  fun () -> Caml.incr c ; Printf.sprintf "__v%d__" !c

module B = struct
  include Ast_builder.Make(struct let loc = Location.none end)
  let elident v = pexp_ident (Located.lident v)
  let econstr s args =
    let args = match args with
      | [] -> None
      | [x] -> Some x
      | l -> Some (pexp_tuple l)
    in
    pexp_construct (Located.lident s) args
  let enil () = econstr "[]" []
  let econs hd tl = econstr "::" [hd; tl]
  let elist l = List.fold_right ~f:econs l ~init:(enil ())
  let pvar v = ppat_var (Located.mk v)
end

type insert_type =
  | Value
  | Path
  | Param

let insert_type_of_ext = function
  | "eval"  -> Value
  | "path"  -> Path
  | "param" -> Param
  | ext -> failwith ("Unknown insert " ^ ext)

class payload_rewriter = object
  inherit [(string * expression * insert_type) list] Ast_traverse.fold_map as super
  method! expression expr acc =
    match expr with
    | { pexp_desc = Pexp_extension ({txt = ext ; _}, payload) ; _ } -> (
        match payload with
        | PStr [ { pstr_desc = Pstr_eval (e, _) ; _ } ] ->
          let id = new_id () in
          let acc' = (id, e, insert_type_of_ext ext) :: acc in
          let expr' = B.elident id in
          expr', acc'
        | _ -> failwith "expected an expression"
      )
    | _ -> super#expression expr acc

end

let add_renamings ~loc deps init =
  List.fold deps ~init ~f:(fun acc (tmpvar, expr, ext) ->
      let rhs = match ext with
        | Path  -> [%expr Bistro.Workflow.eval_path [%e expr]]
        | Param -> [%expr Bistro.Workflow.pure_data [%e expr]]
        | Value -> expr
      in
      [%expr let [%p B.pvar tmpvar] = [%e rhs] in [%e acc]]
    )

let build_applicative ~loc deps code =
  let id = digest (string_of_expression code) in
  match deps with
  | [] ->
    [%expr Bistro.Workflow.pure ~id:[%e B.estring id] [%e code]]
  | (h_tmpvar, _, _) :: t ->
    let tuple_expr =
      List.fold_right t ~init:(B.elident h_tmpvar) ~f:(fun (tmpvar,_,_) acc ->
          [%expr Bistro.Workflow.both [%e B.elident tmpvar] [%e acc]]
        )
    in
    let tuple_pat =
      List.fold_right t ~init:(B.pvar h_tmpvar) ~f:(fun (tmpvar,_,_) acc ->
          Ast_builder.Default.ppat_tuple ~loc [B.pvar tmpvar; acc]
        )
    in
    [%expr
      Bistro.Workflow.app
        (Bistro.Workflow.pure ~id:[%e B.estring id] (fun [%p tuple_pat] -> [%e code]))
        [%e tuple_expr]]
    |> add_renamings deps ~loc

let expression_rewriter ~loc ~path:_ expr =
  let code, deps = new payload_rewriter#expression expr [] in
  build_applicative ~loc deps code

let rec extract_body = function
  | { pexp_desc = Pexp_fun (_,_,_,body) ; _ } -> extract_body body
  | { pexp_desc = Pexp_constraint (expr, ty) ; _ } -> expr, Some ty
  | expr -> expr, None

let rec replace_body new_body = function
  | ({ pexp_desc = Pexp_fun (lab, e1, p, e2) ; _ } as expr) ->
    { expr with pexp_desc = Pexp_fun (lab, e1, p, replace_body new_body e2) }
  | _ -> new_body

let str_item_rewriter ~loc ~path:_ var expr =
  let body, body_type = extract_body expr in
  let rewritten_body, deps = new payload_rewriter#expression body [] in
  let applicative_body = build_applicative ~loc deps [%expr fun () -> [%e rewritten_body]] in
  let workflow_body = [%expr Bistro.Workflow.cached_value [%e applicative_body]] in
  let workflow_body_with_type = match body_type with
    | None -> workflow_body
    | Some ty -> [%expr ([%e workflow_body] : [%t ty])]
  in
  [%stri let [%p B.pvar var] = [%e replace_body workflow_body_with_type expr]]

let expression_ext =
  let open Extension in
  declare "workflow" Context.expression Ast_pattern.(single_expr_payload __) expression_rewriter

let str_item_ext =
  let open Extension in
  let pattern =
    let open Ast_pattern in
    let vb =
      value_binding ~expr:__ ~pat:(ppat_var __)
      (* |> Attribute.pattern np_attr *)
      (* |> Attribute.pattern mem_attr *)
      (* |> Attribute.pattern version_attr *)
      (* |> Attribute.pattern descr_attr *)
    in
    pstr ((pstr_value nonrecursive ((vb ^:: nil))) ^:: nil)
  in
    declare "workflow" Context.structure_item pattern str_item_rewriter

let () =
  Driver.register_transformation "bistro" ~extensions:[ expression_ext ; str_item_ext ]
