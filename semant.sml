structure Semant : sig
  val transProg : Absyn.exp -> {exp: Translate.exp, ty: Types.ty}
end =
struct

(* Useful abbreviations. *)
structure A = Absyn and E = Error and T = Types
val error = ErrorMsg.log
val n = Symbol.name

type pos = int and symbol = Symbol.symbol
type venv = Env.enventry Symbol.table
type expty = {exp: Translate.exp, ty: Types.ty}

(* Non-well-typed expressions are TOP. When a non-well-typed expression
   is encountered, it can be assumed an error has already been reported
   and the type checker should avoid emitting further errors related to
   that type. *)

fun absent (id : Symbol.symbol, list) =
    not (List.exists (fn id' => id = id') list)

(* This only looks up names in the environment (ie, it should not create new T.NAMEs for unbound ids?) *)
fun resolveTyName (tenv, name, pos) =
    case Symbol.look (tenv, name) of
      NONE => (error (E.UnboundType {pos=pos, sym=name});
               T.TOP)
    | SOME ty => ty

(* Take a list of symbols that have been newly introduced in the environment and
   resolve any name pointers. *)
fun resolveTyDecs (new, tenv, pos) = (* Pos is the beginning of the declaration. *)
    let
      fun reportCyclicTypeDec (pos, path) =
          let
            (* Find all the symbols in path that are mapped to by new names in the dec. *)
            val syms = List.filter (fn name =>
                                       (case Symbol.look (tenv, name) of
                                          SOME ty => List.exists (fn ty' => ty = ty')
                                                                 path
                                        | _ => false))
                                   new
          in
            error (E.CyclicTypeDec {pos=pos, syms=syms})
          end
      (* Collect all the Type.NAMEs directly accessible from a given type. *)
      fun collectNameTys name =
          (case Symbol.look (tenv, name) of
             SOME (T.RECORD (fields, _)) =>
             List.filter (fn ty => case ty of
                                     T.NAME _ => true
                                   | _ => false)
                         (map (fn (_, ty) => ty) fields)
           | SOME (T.ARRAY (nameTy as T.NAME _, _)) => [nameTy]
           | SOME (nameTy as T.NAME _) => [nameTy]
           | _ => [])
      fun setTy ty (T.NAME (_, tyref)) = tyref := SOME ty
        | setTy ty1 ty2 = raise Fail ("Trying to resolve non-name type: " ^
                                      (T.toString ty2) ^ " to " ^ (T.toString ty1))
      fun getName (T.NAME (name, _)) = name
        | getName ty = raise Fail ("Trying to get name of " ^ (T.toString ty))
      (* Continuously follow Type.NAMEs through the type environment
       * looking for the non-reference type the NAMEs are intended to
       * point at. Once a "concrete" type has been found, all the
       * NAMEs are updated to point to it, using setTy. If a cycle is
       * found, all NAMEs are pointed to TOP. *)
      fun resolveFully (ty as T.NAME (name, tyref), path) =
          (case !tyref of
             NONE => if List.exists (fn ty' => ty = ty') path then
                       (reportCyclicTypeDec (pos, path);
                        resolveFully (T.TOP, ty :: path))
                     else
                       (case Symbol.look (tenv, name) of
                          NONE => (error (E.UnresolvedType {pos=pos, sym=name});
                                   resolveFully (T.TOP, ty :: path))
                        | SOME ty' => resolveFully (ty', ty :: path))
           | SOME ty' => resolveFully (ty', path))
        | resolveFully (ty, path) = map (setTy ty) path
    in
      map (fn ty => resolveFully (ty, []))
          (List.concat (map collectNameTys new))
    end

fun operTy (A.EqOp) = T.BOTTOM
  | operTy (A.NeqOp) = T.BOTTOM
  | operTy _ = T.INT

(* Absyn.ty -> Types.ty : Construct a type from an AST node *)
(* This is the only place where Types.tys should be created. *)
fun transTy (tenv, A.NameTy (name, _), _) =
    (case Symbol.look (tenv, name) of
       NONE => T.NAME (name, ref NONE)
     (* Use Types.NAME (name, ref (SOME ty))) instead? *)
     | SOME ty => ty)
  | transTy (tenv, A.RecordTy (fields), pos) =
    T.RECORD ((map (fn {name, escape=_, typ, pos=pos'} =>
                       (name, (transTy (tenv, A.NameTy (typ, pos'), pos))))
                   fields),
              pos)
  | transTy (tenv, A.ArrayTy (sym, pos'), pos) =
    T.ARRAY (transTy (tenv, A.NameTy (sym, pos'), pos), pos)

(* (symbol * exp * pos) list * symbol -> exp *)
(* Lookup the entry corresponding to the given field
 * from an Absyn.RecordExp. *)
fun findFieldEntry (fields, field : Symbol.symbol) =
    List.find (fn (field', _, _) => field = field') fields

fun errorIf condition err = if condition then error err else ()

fun expect actual expected err =
    errorIf (T.wellTyped actual andalso T.wellTyped expected andalso
             not (T.subtype actual expected))
            err

(* All adjacent function definitions have been added to
 * the variable environment before this is called, so legal
 * recursive calls will type check just fine. *)
and transFunDec (venv, tenv, {name, params, result, body, pos}) =
    let
      fun bind {name, escape=_, typ, pos} =
          (name, Env.VarEntry {ty=resolveTyName (tenv, typ, pos)})
      val venv' = foldr Symbol.enter' venv (map bind params)
      val {exp=_, ty=actual} = transExp (venv', tenv, false, body)
    in
      case result of
        NONE => expect actual T.UNIT
                       (E.NonUnitProcedure {pos=pos, name=name, body=actual})
      | SOME (typ, pos) => let val expected = resolveTyName (tenv, typ, pos) in
                             expect actual expected
                                    (E.TypeMismatch {pos=pos, actual=actual, expected=expected})
                           end;
      {exp=(), ty=Types.UNIT}
    end

and transDec (venv, tenv, _, A.FunctionDec fundecs) = (* functions *)
    let
      (* Process a function argument specification, adding the type
       * of the argument and its name to an accumulator. The types
       * are used after all args are processed to create an Env.FunEntry
       * and the arugment names are passed along to check uniqueness of
       * subsequent argument names.
       * The function name is curried out for use with fold. *)
      fun paramToFormal func ({name, escape, typ, pos}, (tys, names)) =
          (errorIf (List.exists (fn n' => name = n') names)
                   (E.ArgumentRedefined {pos=pos, name=func, argument=name});
           (tys @ [resolveTyName (tenv, typ, pos)], name :: names))
      fun resultToTy NONE = T.UNIT
        | resultToTy (SOME (typ, pos)) = resolveTyName (tenv, typ, pos)
      fun decToEntry {name, params, result, body, pos} =
          (name, Env.FunEntry {formals=(#1 (foldl (paramToFormal name)
                                                  ([], [])
                                                  params)),
                               result=resultToTy result})
      val venv' = foldr Symbol.enter' venv (map decToEntry fundecs)
    in
      (map (fn fundec => transFunDec (venv', tenv, fundec)) fundecs;
       {venv=venv', tenv=tenv})
    end
  | transDec (venv, tenv, loop, A.VarDec {name, escape, typ, init, pos}) = (* var *)
    let
      val {exp=_, ty=actual} = transExp (venv, tenv, loop, init)
      val declared = case typ of
                       SOME (name, pos) => resolveTyName (tenv, name, pos)
                     | NONE => actual
    in
      errorIf (T.equalTy declared T.NIL) (E.NilInitialization {pos=pos, name=name});
      expect actual declared
             (E.AssignmentMismatch {pos=pos, actual=actual, expected=declared});
      {venv=Symbol.enter (venv, name, Env.VarEntry {ty=declared}), tenv=tenv}
    end
  | transDec (venv, tenv, _, A.TypeDec decs) = (* types *)
    let fun addType ({name, ty, pos}, (new, tenv)) =
            if absent (name, new) then
              (new @ [name], Symbol.enter (tenv, name, transTy (tenv, ty, pos)))
            else (* If the name was already bound by these decs, don't rebind it. *)
              (error (Error.TypeRedefined {pos=pos, name=name});
               (new, tenv))
      val (new, tenv') = foldl addType ([], tenv) decs
      val pos = case List.getItem decs of
                  NONE => 0
                | SOME ({name=_, ty=_, pos}, _) => pos
    in
      resolveTyDecs (new, tenv', pos);
      {venv=venv, tenv=tenv'}
    end

and transExp (venv, tenv, loop, exp) =
    let
      fun getTy exp = #ty (transExp (venv, tenv, loop, exp))

      (* Determine the type of an lvalue. *)
      and transVar (A.SimpleVar (name, pos)) = (* var *)
          (case Symbol.look (venv, name) of
             SOME (Env.VarEntry {ty}) => {exp=(), ty=ty}
           | SOME (Env.FunEntry _) => (error (E.NameBoundToFunction {pos=pos, sym=name});
                                       {exp=(), ty=T.TOP})
           | NONE => (error (E.UndefinedVar {pos=pos, sym=name});
                      {exp=(), ty=T.TOP}))
        | transVar (A.FieldVar (var, field, pos)) = (* record *)
          (case transVar var of
             {exp=_, ty=record as T.RECORD (fields, _)} =>
             (case List.find (fn (f', _) => field = f') fields of
                SOME (_, ty) => {exp=(), ty=ty}
              | NONE => (error (E.NoSuchField {pos=pos, field=field, record=record});
                         {exp=(), ty=T.TOP}))
           | {exp=_, ty} => (error (E.NonRecordAccess {pos=pos, field=field, actual=ty});
                             {exp=(), ty=T.TOP}))
        | transVar (A.SubscriptVar (var, exp, pos)) = (* array *)
          let val actual = getTy exp in
            expect actual T.INT
                   (E.NonIntSubscript {pos=pos, actual=actual});
            case transVar var of
              {exp=_, ty=T.ARRAY (ty, _)} => {exp=(), ty=ty}
            | {exp=_, ty} => (errorIf (T.wellTyped ty)
                                      (E.NonArrayAccess {pos=pos, actual=ty});
                              {exp=(), ty=T.TOP})
          end

      and transCall {func=name, args=arg_exps, pos} =
          (case Symbol.look (venv, name) of
             NONE => (error (E.UndefinedFunction {pos=pos, sym=name});
                      {exp=(), ty=T.TOP})
           | SOME (Env.VarEntry _) => (error (E.NameBoundToVar {pos=pos, sym=name});
                                       {exp=(), ty=T.TOP})
           | SOME (Env.FunEntry {formals, result}) =>
             (* Verify the arg types against the declared types. *)
             (ListPair.appEq (fn (expected, exp) =>
                                 let val actual = getTy exp in
                                   expect actual expected
                                          (E.ArgumentMismatch {pos=(A.getPosExp exp), actual=actual, expected=expected})
                                 end)
                             (formals, arg_exps)
              handle ListPair.UnequalLengths =>
                     error (E.ArityMismatch {pos=pos, name=name, actual=length arg_exps, expected=length formals});
              {exp=(), ty=result}))

      and transOp {left, oper, right, pos} =
          let
            val expected = operTy oper
            val left_ty = getTy left
            val right_ty = getTy right
            val left_join = T.join (left_ty, expected)
            val actual = T.join (if T.wellTyped left_join then left_join else expected, right_ty)
          in
            if T.wellTyped left_ty andalso not (T.wellTyped left_join) then
              error (E.OperandMismatch {pos=(A.getPosExp left), oper=oper, actual=left_ty, expected=expected})
            else if T.wellTyped left_join andalso T.wellTyped right_ty andalso not (T.wellTyped actual) then
              error (E.OperandMismatch {pos=(A.getPosExp right), oper=oper, actual=right_ty, expected=left_join})
            else
              ();
            {exp=(), ty=T.INT}
          end

      and transRecord {fields=field_exps, typ, pos} =
          (case Symbol.look (tenv, typ) of
             SOME (record as Types.RECORD (fields, _)) =>
             let fun checkField (field, expected) =
                     case findFieldEntry (field_exps, field) of
                       SOME (_, exp, pos) =>
                       let val actual = getTy exp in
                         expect actual expected
                                (E.FieldMismatch {pos=pos, field=field, actual=actual, expected=expected})
                       end
                     | NONE => error (E.MissingField {pos=pos, field=field, expected=expected})
             in
               ((map checkField fields); {exp=(), ty=record})
             end
           | SOME actual => (error (E.NonRecordType {pos=pos, sym=typ, actual=actual});
                             {exp=(), ty=T.TOP})
           | NONE => (error (E.UnboundRecordType {pos=pos, sym=typ});
                      {exp=(), ty=T.TOP}))

      and transSeq exps =
          foldl (fn ((exp, _), _) =>
                    transExp (venv, tenv, loop, exp))
                {exp=(), ty=T.UNIT}
                exps

      and transAssign {var, exp, pos} =
          let
            val {exp=_, ty=expected} = transVar var
            val {exp=_, ty=actual} = transExp (venv, tenv, loop, exp)
          in
            (expect actual expected
                    (E.AssignmentMismatch {pos=pos, actual=actual, expected=expected});
             {exp=(), ty=T.UNIT})
          end

      and transIf {test, then', else', pos} =
          let
            val {exp=_, ty=test_ty} = transExp (venv, tenv, loop, test)
            val {exp=_, ty=then_ty} = transExp (venv, tenv, loop, then')
            val else_ty = case else' of
                            NONE => T.UNIT
                          | SOME exp => getTy exp
            val actual = case else' of
                           NONE => T.UNIT
                         | SOME _ => T.join (then_ty, else_ty)
          in
            expect test_ty T.INT
                   (E.ConditionMismatch {pos=(A.getPosExp test), actual=test_ty});
            case else' of
              NONE => expect then_ty T.UNIT
                             (E.NonUnitIf {pos=(A.getPosExp then'), actual=then_ty})
            | SOME exp => errorIf (T.wellTyped then_ty andalso T.wellTyped else_ty andalso
                                   not (T.wellTyped actual))
                                  (E.IfBranchMismatch {pos=(A.getPosExp exp), then'=then_ty, else'=else_ty});
            {exp=(), ty=actual}
          end

      and transWhile {test, body, pos} =
          let
            val {exp=_, ty=test_ty} = transExp (venv, tenv, loop, test)
            val {exp=_, ty=body_ty} = transExp (venv, tenv, true, body)
          in
            expect test_ty T.INT
                   (E.ConditionMismatch {pos=(A.getPosExp test), actual=test_ty});
            expect body_ty T.UNIT
                   (E.NonUnitWhile {pos=(A.getPosExp body), actual=body_ty});
            {exp=(), ty=Types.UNIT}
          end

      and transFor {var, escape, lo, hi, body, pos} =
          let
            val {exp=_, ty=lo_ty} = transExp (venv, tenv, loop, lo)
            val {exp=_, ty=hi_ty} = transExp (venv, tenv, loop, hi)
            val venv' = Symbol.enter (venv, var, Env.VarEntry {ty=Types.INT})
            val {exp=_, ty=body_ty} = transExp (venv', tenv, true, body)
          in
            expect lo_ty Types.INT
                   (E.ForRangeMismatch {pos=(A.getPosExp lo), which="lower", actual=lo_ty});
            expect hi_ty Types.INT
                   (E.ForRangeMismatch {pos=(A.getPosExp hi), which="upper", actual=hi_ty});
            expect body_ty Types.UNIT
                   (E.NonUnitFor {pos=pos, actual=body_ty});
            {exp=(), ty=T.UNIT}
          end

      and transLet {decs, body, pos} =
          let val {venv=venv', tenv=tenv'} =
                  foldl (fn (dec, {venv, tenv}) =>
                            transDec (venv, tenv, loop, dec))
                        {venv=venv, tenv=tenv}
                        decs
          in transExp (venv', tenv', loop, body) end

      and transArray {typ, size, init, pos} =
          let
            val {exp=_, ty=size_ty} = transExp (venv, tenv, loop, size)
            val {exp=_, ty=init_ty} = transExp (venv, tenv, loop, init)
          in
            expect size_ty T.INT
                   (E.ArraySizeMismatch {pos=(A.getPosExp size), actual=size_ty});
            case resolveTyName (tenv, typ, pos) of
              array_ty as T.ARRAY (element_ty, _) =>
              (expect init_ty element_ty
                      (E.ArrayInitMismatch {pos=(A.getPosExp init),
                                            actual=init_ty,
                                            expected=element_ty});
               {exp=(), ty=array_ty})
            | actual => (errorIf (T.wellTyped actual)
                                 (E.NonArrayType {pos=pos, sym=typ, actual=actual});
                         {exp=(), ty=T.TOP})
          end
    in
      case exp of
        A.NilExp _ => {exp=(), ty=T.NIL}
      | A.IntExp _ => {exp=(), ty=T.INT}
      | A.StringExp _ => {exp=(), ty=T.STRING}
      | A.VarExp var => transVar var
      | A.CallExp call => transCall call
      | A.OpExp op' => transOp op'
      | A.RecordExp record => transRecord record
      | A.SeqExp (exps, _) => transSeq exps
      | A.AssignExp assign => transAssign assign
      | A.IfExp if' => transIf if'
      | A.WhileExp while' => transWhile while'
      | A.ForExp for => transFor for
      | A.LetExp let' => transLet let'
      | A.ArrayExp array => transArray array
      | A.BreakExp pos =>
        (errorIf (not loop) (E.IllegalBreak {pos=pos});
         {exp=(), ty=Types.BOTTOM})
    end

fun transProg exp = transExp (Env.base_venv, Env.base_tenv, false, exp)

end