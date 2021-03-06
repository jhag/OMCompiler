/*
 * This file is part of OpenModelica.
 *
 * Copyright (c) 1998-2014, Open Source Modelica Consortium (OSMC),
 * c/o Linköpings universitet, Department of Computer and Information Science,
 * SE-58183 Linköping, Sweden.
 *
 * All rights reserved.
 *
 * THIS PROGRAM IS PROVIDED UNDER THE TERMS OF GPL VERSION 3 LICENSE OR
 * THIS OSMC PUBLIC LICENSE (OSMC-PL) VERSION 1.2.
 * ANY USE, REPRODUCTION OR DISTRIBUTION OF THIS PROGRAM CONSTITUTES
 * RECIPIENT'S ACCEPTANCE OF THE OSMC PUBLIC LICENSE OR THE GPL VERSION 3,
 * ACCORDING TO RECIPIENTS CHOICE.
 *
 * The OpenModelica software and the Open Source Modelica
 * Consortium (OSMC) Public License (OSMC-PL) are obtained
 * from OSMC, either from the above address,
 * from the URLs: http://www.ida.liu.se/projects/OpenModelica or
 * http://www.openmodelica.org, and in the OpenModelica distribution.
 * GNU version 3 is obtained from: http://www.gnu.org/copyleft/gpl.html.
 *
 * This program is distributed WITHOUT ANY WARRANTY; without
 * even the implied warranty of  MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE, EXCEPT AS EXPRESSLY SET FORTH
 * IN THE BY RECIPIENT SELECTED SUBSIDIARY LICENSE CONDITIONS OF OSMC-PL.
 *
 * See the full OSMC Public License conditions for more details.
 *
 */

encapsulated package NFFunc
" file:        NFFunc.mo
  package:     NFFunc
  description: package for handling functions.


  Functions used by NFInst for handling functions.
"

import Binding = NFBinding;
import NFClass.Class;
import NFComponent.Component;
import Dimension = NFDimension;
import NFEquation.Equation;
import NFExpression.Expression;
import NFExpression.CallAttributes;
import NFInstNode.InstNode;
import NFMod.Modifier;
import NFStatement.Statement;
import Type = NFType;
import ComponentRef = NFComponentRef;

protected
import Config;
import Error;
import Inst = NFInst;
import InstUtil;
import List;
import Lookup = NFLookup;
import NFInstUtil;
import Record = NFRecord;
import Static;
import TypeCheck = NFTypeCheck;
import Types;
import Typing = NFTyping;

public
type SlotType = enumeration(POSITIONAL, NAMED, GENERIC);

uniontype Slot
  record SLOT
    String name "The name of the parameter.";
    SlotType ty "The type of parameter (positional, named or both).";
    Option<Expression> default "Default value for the parameter, if any.";
    Option<Expression> arg "Value from function call argument if given by the call.";
  end SLOT;
end Slot;

uniontype Slots
  record SLOTS
    InstNode fnNode;
    array<Slot> slots;
  end SLOTS;
end Slots;

public
function instCall
  input Absyn.ComponentRef functionName;
  input Absyn.FunctionArgs functionArgs;
  input InstNode scope;
  input SourceInfo info;
  output Expression callExp;
protected
  Absyn.Path fn_path;
  ComponentRef fn_cref;
  InstNode fn_node;
  list<Slots> slots;
  Slots filled_slots;
  list<Expression> args;
  list<tuple<String, Expression>> named_args;
algorithm
  // Look up the function.
  (fn_path, fn_cref) := lookupFunc(functionName, scope, info);

  // TODO: The instantiated function (and slots?) needs to be stored somewhere.
  // Instantiate the function.
  ComponentRef.CREF(node = fn_node) := fn_cref;
  fn_node := Inst.instantiate(fn_node);
  Inst.instExpressions(fn_node);

  // Instantiate the arguments.
  (args, named_args) := instArgs(functionArgs, scope, info);

  // Create an array of function parameter slots.
  slots := makeSlots(fn_node);

  // Fill the slots with the given function arguments.
  filled_slots := fillSlots(args, named_args, slots, info);

  // Collect the placed arguments from the slots.
  args := collectArgs(filled_slots, info);

  // Construct the call expression.
  callExp := Expression.CALL(fn_path, fn_cref, args, NONE());
end instCall;

function lookupFunc
  input Absyn.ComponentRef functionName;
  input InstNode scope;
  input SourceInfo info;
  output Absyn.Path functionPath;
  output ComponentRef functionRef;
protected
  list<InstNode> nodes;
  InstNode found_scope;
algorithm
  try
    // Make sure the name is a path.
    functionPath := Absyn.crefToPath(functionName);
  else
    Error.addSourceMessageAndFail(Error.SUBSCRIPTED_FUNCTION_CALL,
      {Dump.printComponentRefStr(functionName)}, info);
  end try;

  // Look up the function and create a cref for it.
  (_, nodes, found_scope) := Lookup.lookupFunctionName(functionName, scope, info);
  functionRef := ComponentRef.fromNodeList(InstNode.scopeList(found_scope));
  functionRef := Inst.makeCref(functionName, nodes, scope, info, functionRef);
end lookupFunc;

function instArgs
  input Absyn.FunctionArgs args;
  input InstNode scope;
  input SourceInfo info;
  output list<Expression> posArgs;
  output list<tuple<String, Expression>> namedArgs;
algorithm
  (posArgs, namedArgs) := match args
    case Absyn.FUNCTIONARGS()
      algorithm
        posArgs := list(Inst.instExp(a, scope, info) for a in args.args);
        namedArgs := list(instNamedArg(a, scope, info) for a in args.argNames);
      then
        (posArgs, namedArgs);

    else
      algorithm
        assert(false, getInstanceName() + " got unknown function args");
      then
        fail();
  end match;
end instArgs;

function instNamedArg
  input Absyn.NamedArg absynArg;
  input InstNode scope;
  input SourceInfo info;
  output tuple<String, Expression> arg;
protected
  String name;
  Absyn.Exp exp;
algorithm
  Absyn.NAMEDARG(argName = name, argValue = exp) := absynArg;
  arg := (name, Inst.instExp(exp, scope, info));
end instNamedArg;

function makeSlots
  input InstNode functionNode;
  output list<Slots> slots;
protected
  Class cls;
  list<Slot> sl;
algorithm
  cls := InstNode.getClass(functionNode);

  slots := match cls
    case Class.INSTANCED_CLASS()
      algorithm
        sl := makeSlotsFromComponents(cls.components);
      then
        {SLOTS(functionNode, listArray(sl))};

    // TODO: Handle Integer() and String() here.
    case Class.INSTANCED_BUILTIN()
      algorithm
      then
        {};
  end match;
end makeSlots;

function makeSlotsFromComponents
  input array<InstNode> components;
  input list<Slot> accumSlots = {};
  output list<Slot> slots = accumSlots;
protected
  Slot s;
  Component comp;
  Option<Expression> default;
algorithm
  for c in components loop
    if InstNode.isComponent(c) then
      // A normal component. Add a slot for it if it's an input.
      comp := InstNode.component(c);

      slots := match comp
        case Component.UNTYPED_COMPONENT(attributes =
            Component.ATTRIBUTES(direction = DAE.INPUT()))
          algorithm
            default := Binding.untypedExp(comp.binding);
          then
            SLOT(InstNode.name(c), SlotType.GENERIC, default, NONE()) :: slots;

        else slots;
      end match;
    else
      // An extends node. Recurse into it to collect all slots.
      slots := makeSlotsFromComponents(Class.components(InstNode.getClass(c)), slots);
    end if;
  end for;
end makeSlotsFromComponents;

function fillSlots
  input list<Expression> posArgs;
  input list<tuple<String, Expression>> namedArgs;
  input list<Slots> slots;
  input SourceInfo info;
  output Slots filledSlots;
algorithm
  filledSlots := listHead(slots);
end fillSlots;

function collectArgs
  input Slots slots;
  input SourceInfo info;
  output list<Expression> args = {};
protected
  array<Slot> sl;
  Expression e;
  Option<Expression> default, arg;
  String name;
algorithm
  SLOTS(slots = sl) := slots;

  for s in sl loop
    SLOT(name = name, default = default, arg = arg) := s;

    e := match (default, arg)
      case (_, SOME(e)) then e; // Use the argument from the call if one was given.
      case (SOME(e), _) then e; // Otherwise, use the default value for the parameter.
      else // Give an error if no argument was given and there's no default value.
        algorithm
          Error.addSourceMessage(Error.UNFILLED_SLOT, {name}, info);
        then
          fail();
    end match;

    args := e :: args;
  end for;
end collectArgs;

//import Binding = NFBinding;
//import NFClass.Class;
//import NFComponent.Component;
//import Dimension = NFDimension;
//import NFEquation.Equation;
//import NFExpression.Expression;
//import NFExpression.CallAttributes;
//import NFInstNode.InstNode;
//import NFMod.Modifier;
//import NFPrefix.Prefix;
//import NFStatement.Statement;
//import Type = NFType;
//import Subscript = NFSubscript;
//
//protected
//import Config;
//import Error;
//import Inst = NFInst;
//import InstUtil;
//import List;
//import Lookup = NFLookup;
//import NFInstUtil;
//import Record = NFRecord;
//import Static;
//import TypeCheck = NFTypeCheck;
//import Types;
//import Typing = NFTyping;
//
//public
//public uniontype FunctionSlot
//  record SLOT
//    String name "the name of the slot";
//    Option<tuple<Expression, Type, DAE.Const>> arg "the argument given by the function call";
//    Binding default "the default value from binding of the input component in the function";
//    Option<tuple<Type, DAE.Const>> expected "the actual type of the input component, what we expect to get";
//    Boolean isFilled;
//  end SLOT;
//end FunctionSlot;
//
//public
//function typeFunctionCall
//  input Absyn.ComponentRef functionName;
//  input Absyn.FunctionArgs functionArgs;
//  input InstNode scope;
//  input SourceInfo info;
//  output Expression typedExp;
//  output Type ty;
//  output DAE.Const variability;
//protected
//  String fn_name;
//  Absyn.Path fn, fn_1;
//  InstNode fakeComponent;
//  InstNode classNode, foundScope;
//  list<Expression> arguments;
//  DAE.CallAttributes ca;
//  Type classType, resultType;
//  list<DAE.FuncArg> funcArg;
//  DAE.FunctionAttributes functionAttributes;
//  Prefix prefix;
//  SCode.Element cls;
//  list<DAE.Var> vars;
//  list<Absyn.Exp> args;
//  DAE.Const argVariability;
//  DAE.FunctionBuiltin isBuiltin;
//  Boolean builtin;
//  DAE.InlineType inlineType;
//  Lookup.LookupState state;
//algorithm
//  try
//    // make sure the component is a path (no subscripts)
//    fn := Absyn.crefToPath(functionName);
//  else
//    fn_name := Dump.printComponentRefStr(functionName);
//    Error.addSourceMessageAndFail(Error.SUBSCRIPTED_FUNCTION_CALL, {fn_name}, info);
//    fail();
//  end try;
//
//  // TODO: Revise this
//  try
//    (classNode, _, foundScope, state) := Lookup.lookupCref(functionName, scope, info);
//    prefix := InstNode.prefix(foundScope);
//    cls := InstNode.definition(classNode);
//
//    if SCode.isRecord(cls) then
//      classNode := Inst.instantiate(classNode, Modifier.NOMOD(), scope);
//      (classNode, classType) := Typing.typeClass(classNode);
//      (typedExp, ty, variability) := Record.typeRecordCall(functionName, functionArgs, prefix, classNode, classType, scope, info);
//    elseif isBuiltinFunctionName(functionName) then
//      classNode := Inst.instantiate(classNode, Modifier.NOMOD(), scope);
//      (classNode, classType) := Typing.typeClass(classNode);
//      (typedExp, ty, variability) := typeBuiltinFunctionCall(functionName, functionArgs, prefix, classNode, classType, cls, scope, info);
//    else
//      // assertfunction here.
//      // (classNode, foundScope) := Lookup.lookupFunctionName(functionName, scope, info);
//      classNode := Inst.instantiate(classNode, Modifier.NOMOD(), scope);
//      (classNode, classType) := Typing.typeClass(classNode);
//      (typedExp, ty, variability) := typeNormalFunction(functionName, functionArgs, prefix, classNode, classType, scope, info);
//    end if;
//  else
//    // we could not lookup the class, see if is a special builtin such as String(), etc
//    if isSpecialBuiltinFunctionName(functionName) then
//      (typedExp, ty, variability) := typeSpecialBuiltinFunctionCall(functionName, functionArgs, prefix, classNode, scope, info);
//      return;
//    end if;
//    // fail otherwise
//    fail();
//  end try;
//
//end typeFunctionCall;
//
//function typeNormalFunction
//  input Absyn.ComponentRef funcName;
//  input Absyn.FunctionArgs callArgs;
//  input Prefix prefix;
//  input InstNode classNode;
//  input Type classType;
//  input InstNode scope;
//  input SourceInfo info;
//  output Expression typedExp;
//  output Type ty;
//  output DAE.Const variability;
//protected
//  Absyn.Path fn;
//  InstNode ty_node;
//  NFExpression.CallAttributes ca;
//  Type resultType;
//  DAE.FunctionAttributes functionAttributes;
//  list<Absyn.Exp> posargs;
//  list<Absyn.NamedArg> namedargs;
//  DAE.FunctionBuiltin isBuiltin;
//  Boolean builtin;
//  DAE.InlineType inlineType;
//  list<InstNode> inputs;
//  list<Expression> dargs, callExps;
//  Expression argExp;
//  Type argTy;
//  DAE.Const argConst;
//  list<FunctionSlot> slots;
//  FunctionSlot sl;
//  list<Dimension> vectDims;
//  SCode.Element cls;
//
//algorithm
//
//  fn := Absyn.crefToPath(funcName);
//  inputs := getFunctionInputs(classNode);
//
//  slots := createAndFillSlots(funcName, prefix, inputs, callArgs, scope, info);
//
//  // check that there are no unfilled slots and the types of actual arguments agree with the type of function arguments
//  (slots,vectDims) := typeCheckFunctionSlots(slots, fn, prefix, info);
//
//  (dargs, variability) := argsFromSlots(slots);
//
//  Type.COMPLEX(cls = ty_node) := classType;
//  functionAttributes := getFunctionAttributes(ty_node);
//  ty := makeFunctionType(ty_node, functionAttributes);
//
//  Type.FUNCTION(resultType = resultType) := ty;
//
//  (isBuiltin, builtin, fn) := isBuiltinFunc(fn, functionAttributes);
//  inlineType := Static.inlineBuiltin(isBuiltin,functionAttributes.inline);
//
//  ca := CallAttributes.CALL_ATTR(
//          resultType,
//          Type.isTuple(resultType),
//          builtin,
//          functionAttributes.isImpure or (not functionAttributes.isOpenModelicaPure),
//          functionAttributes.isFunctionPointer,
//          inlineType,DAE.NO_TAIL());
//
//  if listLength(vectDims) == 0 then
//    typedExp := Expression.CALL(fn, Expression.CREF(classNode, prefix), dargs, ca);
//  else
//    // ty := Type.liftArrayLeftList(ty, vectDims);
//    callExps := vectorizeCall(fn, classNode, prefix, dargs, ca, vectDims);
//    typedExp := Expression.arrayFromList(callExps, ty, vectDims);
//  end if;
//end typeNormalFunction;
//
//function getFunctionInputs
//  input InstNode classNode;
//  output list<InstNode> inputs = {};
//protected
//  InstNode cn;
//  Component.Attributes attr;
//  array<InstNode> components;
//algorithm
//  Class.INSTANCED_CLASS(components = components) := InstNode.getClass(classNode);
//
//  for i in arrayLength(components):-1:1 loop
//     cn := components[i];
//     attr := Component.getAttributes(InstNode.component(cn));
//     inputs := match attr
//                 case Component.ATTRIBUTES(direction = DAE.INPUT()) then cn::inputs;
//                 else inputs;
//               end match;
//  end for;
//end getFunctionInputs;
//
//function getFunctionOutputs
//  input InstNode classNode;
//  output list<InstNode> outputs = {};
//protected
//  InstNode cn;
//  Component.Attributes attr;
//  array<InstNode> components;
//algorithm
//  Class.INSTANCED_CLASS(components = components) := InstNode.getClass(classNode);
//
//  for i in arrayLength(components):-1:1 loop
//     cn := components[i];
//     attr := Component.getAttributes(InstNode.component(cn));
//     outputs := match attr
//                 case Component.ATTRIBUTES(direction = DAE.OUTPUT()) then cn::outputs;
//                 else outputs;
//               end match;
//  end for;
//end getFunctionOutputs;
//
//function createAndFillSlots
//  input Absyn.ComponentRef funcName;
//  input Prefix prefix;
//  input list<InstNode> funcInputs;
//  input Absyn.FunctionArgs callArgs;
//  input InstNode callScope;
//  input SourceInfo info;
//  output list<FunctionSlot> filledSlots;
//protected
//  Component comp;
//  DAE.VarKind vari;
//  DAE.Const consts;
//  list<Absyn.Exp> posargs;
//  list<Absyn.NamedArg> namedargs;
//  FunctionSlot sl;
//  list<FunctionSlot> slots, posfilled;
//  Expression argExp;
//  Type argTy;
//  DAE.Const argConst;
//algorithm
//
//  slots := {};
//  for compnode in funcInputs loop
//    comp := InstNode.component(compnode);
//    vari := Component.variability(comp);
//    consts := Typing.variabilityToConst(NFInstUtil.daeToSCodeVariability(vari));
//    slots := SLOT(InstNode.name(compnode),
//                  NONE(),
//                  Component.getBinding(comp),
//                  SOME((Component.getType(comp), consts)),
//                  false)::slots;
//  end for;
//  slots := listReverse(slots);
//
//  Absyn.FUNCTIONARGS(args = posargs, argNames = namedargs) := callArgs;
//
//  posfilled := {};
//  // handle positional args
//  for arg in posargs loop
//    (argExp, argTy, argConst) := Typing.typeExp(arg, callScope, info);
//    sl::slots := slots;
//    sl := fillPosSlotWithArg(sl,(argExp, argTy, argConst));
//    posfilled := sl::posfilled;
//  end for;
//  slots := listAppend(listReverse(posfilled), slots);
//
//  // handle named args
//  for narg in namedargs loop
//    Absyn.NAMEDARG() := narg;
//    (argExp, argTy, argConst) := Typing.typeExp(narg.argValue, callScope, info);
//    slots := fillNamedSlot(slots, narg.argName, (argExp, argTy, argConst), Absyn.crefToPath(funcName), prefix, info);
//  end for;
//
//  filledSlots := slots;
//end createAndFillSlots;
//
//function fillPosSlotWithArg
//  input output FunctionSlot inSlot;
//  input tuple<Expression, Type, DAE.Const> newArg;
//algorithm
//  SLOT() := inSlot;
//  inSlot.arg := SOME(newArg);
//  inSlot.isFilled := true;
//end fillPosSlotWithArg;
//
//function fillNamedSlot
//  input list<FunctionSlot> islots;
//  input String name;
//  input tuple<Expression, Type, DAE.Const> arg;
//  input Absyn.Path fn;
//  input Prefix prefix;
//  input SourceInfo info;
//  output list<FunctionSlot> oslots = {};
//protected
//  String str;
//  Boolean b, found = false;
//  String sname "the name of the slot";
//  Option<tuple<Expression, Type, DAE.Const>> sarg "the argument given by the function call";
//  Binding sdefault "the default value from binding of the input component in the function";
//  Option<tuple<Type, DAE.Const>> sexpected "the actual type of the input component, what we expect to get";
//  Boolean sisFilled;
//algorithm
//  for s in islots loop
//    SLOT(sname, sarg, sdefault, sexpected, sisFilled) := s;
//    if (name == sname) then
//      found := true;
//      // if the slot is already filled, Huston we have a problem, add an error
//      if sisFilled then
//        str := Prefix.toString(prefix) + "." + Absyn.pathString(fn);
//        Error.addSourceMessageAndFail(Error.FUNCTION_SLOT_ALLREADY_FILLED, {name, str}, info);
//      end if;
//      oslots := SLOT(sname, SOME(arg), sdefault, sexpected, true) :: oslots;
//    else
//      oslots := s :: oslots;
//    end if;
//  end for;
//  if not found then
//    str := Prefix.toString(prefix) + "." + Absyn.pathString(fn);
//    Error.addSourceMessageAndFail(Error.NO_SUCH_ARGUMENT, {str, name}, info);
//  end if;
//end fillNamedSlot;
//
//function argsFromSlots
//  input list<FunctionSlot> slots;
//  output list<Expression> args = {};
//  output DAE.Const c = DAE.C_CONST();
//protected
//  Integer d;
//  Expression arg;
//  Option<tuple<Expression, Type, DAE.Const>> sarg "the argument given by the function call";
//  Binding sdefault "the default value from binding of the input component in the function";
//  DAE.Const const;
//algorithm
//  for s in slots loop
//    SLOT(arg = sarg, default = sdefault) := s;
//    if isSome(sarg) then
//      SOME((arg, _, const)) := sarg;
//      c := Types.constAnd(c, const);
//    else
//      _ := match sdefault
//      // TODO FIXME what do we do with the propagatedDims?
//        case Binding.TYPED_BINDING()
//          algorithm
//            c := Types.constAnd(c, sdefault.variability);
//            arg := sdefault.bindingExp;
//          then ();
//        else
//          algorithm
//            Error.addMessage(Error.INTERNAL_ERROR, {"NFFunc.argsFromSlots failed."});
//          then fail();
//        end match;
//    end if;
//    args := arg :: args;
//  end for;
//  args := listReverse(args);
//end argsFromSlots;
//
//function typeCheckFunctionSlots
//  input list<FunctionSlot> slots;
//  input Absyn.Path fn;
//  input Prefix prefix;
//  input SourceInfo info;
//  output list<FunctionSlot> outslots;
//  output list<Dimension> vectDims;
//algorithm
//protected
//  String str1, str2, s1, s2, s3, s4, s5;
//  Boolean b, found = false;
//  String sname "the name of the slot";
//  Option<tuple<Expression, Type, DAE.Const>> sarg "the argument given by the function call";
//  Binding sdefault "the default value from binding of the input component in the function";
//  Option<tuple<Type, DAE.Const>> sexpected "the actual type of the input component, what we expect to get";
//  Boolean sisFilled, compatible;
//  Expression expActual, expMatched;
//  DAE.Const vrActual, vrExpected;
//  Type tyActual, tyExpected, tyMatched, ty1,ty2;
//  list<Dimension> dims1,dims2;
//  Integer position = 0;
//
//algorithm
//  outslots := {};
//  vectDims := {};
//
//  for s in slots loop
//    position := position + 1;
//    SLOT(sname, sarg, sdefault, sexpected, sisFilled) := s;
//
//    // slot is filled, i.e, an argument has been specified.
//    if sisFilled then
//	    SOME((expActual, tyActual, vrActual)) := sarg;
//	    SOME((tyExpected, vrExpected)) := sexpected;
//
//	    // fail if the variability is wrong
//	    if not Types.constEqualOrHigher(vrActual, vrExpected) then
//	      str1 := Expression.toString(expActual);
//	      str2 := DAEUtil.constStrFriendly(vrExpected);
//	      Error.addSourceMessageAndFail(Error.FUNCTION_SLOT_VARIABILITY, {sname, str1, str2}, info);
//	    end if;
//
//	    // check the types match
//	    (expMatched, tyMatched, compatible) := TypeCheck.matchTypes(tyActual, tyExpected, expActual, false);
//
//	    // If types don't match check the element types to see if it is a dimension issue. If so we try vectorization
//	    if not compatible then
//	      ty1 := Type.elementType(tyActual);
//	      ty2 := Type.elementType(tyExpected);
//	      (expMatched, tyMatched, compatible) := TypeCheck.matchTypes(ty1, ty2, expActual, false);
//
//	      // if even the element types are different then fail.
//	      if not compatible then
//		      s1 := intString(position);
//		      s2 := Absyn.pathStringNoQual(fn);
//		      s3 := Expression.toString(expActual);
//		      s4 := Type.toString(tyActual);
//		      s5 := Type.toString(tyExpected);
//		      Error.addSourceMessage(Error.ARG_TYPE_MISMATCH, {s1,s2,sname,s3,s4,s5}, info);
//		      fail();
//		    // If the element types are the same then try to find a vectorization dim.
//		    // Matching RESTARTS from the first argument again in vectorize mode.
//	      else
//	        dims1 := Type.getTypeDims(tyActual);
//	        dims2 := Type.getTypeDims(tyExpected);
//	        vectDims := findVectorizationDim(dims1,dims2);
//	        outslots := vectorizeTypeCheckFunctionSlots(slots, fn, prefix, info, vectDims);
//	        return;
//	      end if;
//	    end if;
//
//	  // Argument has not been given but there is a default value.
//	  // Right now bindings are not typechecked with the declaration when they reach here.
//	  // That will change soon so this is just enough.
//    elseif Binding.isBound(sdefault) then
//      Binding.TYPED_BINDING(expMatched, tyMatched, vrActual) := sdefault;
//    // No argument. No default value.
//    else
//      Error.addSourceMessage(Error.UNFILLED_SLOT, {sname}, info);
//      fail();
//    end if;
//
//    outslots := SLOT(sname, SOME((expMatched, tyMatched, vrActual)), sdefault, sexpected, sisFilled)::outslots;
//
//  end for;
//
//  outslots := listReverse(outslots);
//end typeCheckFunctionSlots;
//
//function vectorizeTypeCheckFunctionSlots
//  input list<FunctionSlot> slots;
//  input Absyn.Path fn;
//  input Prefix prefix;
//  input SourceInfo info;
//  input list<Dimension> vectDims;
//  output list<FunctionSlot> outslots;
//algorithm
//protected
//  String str1, str2, s1, s2, s3, s4, s5;
//  Boolean b, found = false;
//  String sname "the name of the slot";
//  Option<tuple<Expression, Type, DAE.Const>> sarg "the argument given by the function call";
//  Binding sdefault "the default value from binding of the input component in the function";
//  Option<tuple<Type, DAE.Const>> sexpected "the actual type of the input component, what we expect to get";
//  Boolean sisFilled, compatible;
//  Expression expActual, expMatched;
//  DAE.Const vrActual, vrExpected;
//  Type tyActual, tyExpected, tyMatched, ty1,ty2;
//  Dimension dim;
//  list<Dimension> dims1,dims2;
//  Integer position = 0;
//
//algorithm
//  outslots := {};
//
//  for s in slots loop
//    position := position + 1;
//    SLOT(sname, sarg, sdefault, sexpected, sisFilled) := s;
//
//    // slot is filled
//    if sisFilled then
//	    SOME((expActual, tyActual, vrActual)) := sarg;
//	    SOME((tyExpected, vrExpected)) := sexpected;
//
//	        // fail if the variability is wrong
//	    if not Types.constEqualOrHigher(vrActual, vrExpected) then
//	      str1 := Expression.toString(expActual);
//	      str2 := DAEUtil.constStrFriendly(vrExpected);
//	      Error.addSourceMessageAndFail(Error.FUNCTION_SLOT_VARIABILITY, {sname, str1, str2}, info);
//	    end if;
//
//	    // check the typing
//	    (expMatched, tyMatched, compatible) := TypeCheck.matchTypes(tyActual, tyExpected, expActual, false);
//	    // If the original argument is type compatible then it needs to be repeated
//	    // for each call. Create an array of it.
//	    if compatible then
//	      dims1 := listReverse(vectDims);
//	      for vdim in dims1 loop
//	        tyMatched := Type.liftArrayLeft(tyMatched,vdim);
//	        expMatched := Expression.ARRAY(tyMatched,List.fill(expMatched, Dimension.size(vdim)));
//	      end for;
//	    // If it is not compatible see if it is a dimension issue.
//	    // We can still have actual type mismathc here because we try vectorization
//	    // immidiately when we have dim mistmatch in normal mode. There might be unchecked
//	    // args.
//	    else
//	      ty1 := Type.elementType(tyActual);
//	      ty2 := Type.elementType(tyExpected);
//	      (expMatched, tyMatched, compatible) := TypeCheck.matchTypes(ty1, ty2, expActual, false);
//	      // if even the element types are different then fail.
//	      if not compatible then
//	        s1 := intString(position);
//	        s2 := Absyn.pathStringNoQual(fn);
//	        s3 := Expression.toString(expActual);
//	        s4 := Type.toString(tyActual);
//	        s5 := Type.toString(tyExpected);
//	        Error.addSourceMessage(Error.ARG_TYPE_MISMATCH, {s1,s2,sname,s3,s4,s5}, info);
//	        fail();
//	      // if the element types are the same then lift the expected argument with the
//	      // vectorization dim and mathc it again. If this passes then vectorization is possible
//	      // for this argument.
//	      else
//	        ty2 := Type.liftArrayLeftList(tyExpected,vectDims);
//	        dims2 := Type.getTypeDims(ty2);
//          dims1 := Type.getTypeDims(tyActual);
//	        if Dimension.allEqual(dims1,dims2) then
//	          (expMatched, tyMatched, compatible) := TypeCheck.matchTypes(tyActual, ty2, expActual, false);
//	        else
//	          fail();
//	        end if;
//	      end if;
//	    end if;
//
//	  // Argument is not given but there is a default value.
//	  // Create an array of the default value for each call.
//	  elseif Binding.isBound(sdefault) then
//      Binding.TYPED_BINDING(expMatched, tyMatched, vrActual) := sdefault;
//      dims1 := listReverse(vectDims);
//      for vdim in dims1 loop
//        tyMatched := Type.liftArrayLeft(tyMatched,vdim);
//        expMatched := Expression.ARRAY(tyMatched,List.fill(expMatched, Dimension.size(vdim)));
//      end for;
//    // No argument give and no default value.
//    else
//      Error.addSourceMessage(Error.UNFILLED_SLOT, {sname}, info);
//      fail();
//    end if;
//
//    outslots := SLOT(sname, SOME((expMatched, tyMatched, vrActual)), sdefault, sexpected, sisFilled)::outslots;
//
//  end for;
//
//  outslots := listReverse(outslots);
//end vectorizeTypeCheckFunctionSlots;
//
//function vectorizeCall
//  input Absyn.Path inFnName;
//  input InstNode classNode;
//  input Prefix prefix;
//  input list<Expression> inArgs;
//  input CallAttributes inAttrs;
//  input list<Dimension> vecDims;
//  output list<Expression> outCalls;
//protected
//  list<list<Subscript>> vectsubs;
//  list<list<Expression>> vecargslst;
//algorithm
//
//  // Create combinations of each dims subs, i.e., expand an array[dims]
//  vectsubs := vectorizeDims(vecDims);
//
//  // Apply the set of subs to each argument, i.e., expand each arg.
//  vecargslst := {};
//  for currsubs in vectsubs loop
//    vecargslst := list(Expression.subscript(arg, currsubs) for arg in inArgs)::vecargslst;
//  end for;
//
//
//  outCalls := {};
//  for args in vecargslst loop
//    outCalls := Expression.CALL(inFnName, Expression.CREF(classNode, prefix), args, inAttrs)::outCalls;
//  end for;
//
//  /*
//  for dim in vecDims loop
//    for idx in 1:dimSize
//      vargs := {};
//      for arg in args loop
//        vargs := Expression.subscriptExp(arg,{DAE.INDEX(idx)})::vargs
//      end for;
//      vargs := listReverse(vargs);
//      vargslist := vargslist::vargs;
//      vcalls := Expression.CALL(fn, vargs, ca)::vcalls;
//    end for;
//    vcalls := listReverse(vcalls);
//  end for;
//  */
//end vectorizeCall;
//
//function vectorizeDims
//  "This should go either in NFDimension or NFSubscript."
//  input list<Dimension> vecDims;
//  output list<list<Subscript>> vectsubs;
//protected
//  list<Integer> dimsizes;
//  list<Subscript> subs;
//  list<list<Subscript>> subslstlst;
//algorithm
//
//  // Get the size of each vectorization dim
//  dimsizes := list(Dimension.size(d) for d in vecDims);
//
//  // Expand each dim to subscripts
//  subslstlst := {};
//  for dimsize in dimsizes loop
//    subslstlst := list(Subscript.INDEX(Expression.INTEGER(i)) for i in 1:dimsize)::subslstlst;
//  end for;
//  subslstlst := listReverse(subslstlst);
//
//  // Create combinations of each dims subs, i.e., expand an array[dims]
//  vectsubs := List.combination(subslstlst);
//end vectorizeDims;
//
//public function findVectorizationDim
//"@mahge:
//TODO: rewirite me
//This function basically finds the diff between two dims. The resulting dimension
//is used for vectorizing calls.
//
//e.g. dim1=[2,3,4,2]  dim2=[4,2], findVectorizationDim(dim1,dim2) => [2,3]
//     dim1=[2,3,4,2]  dim2=[3,4,2], findVectorizationDim(dim1,dim2) => [2]
//     dim1=[2,3,4,2]  dim2=[4,3], fail
//"
// input list<Dimension> inGivenDims;
// input list<Dimension> inExpectedDims;
// output list<Dimension> outVectDims;
//algorithm
// outVectDims := matchcontinue(inGivenDims, inExpectedDims)
//   local
//     list<Dimension> dims1;
//     Dimension dim1;
//
//   case(_, {}) then inGivenDims;
//
//   case(_, _)
//     equation
//       true = Dimension.allEqual(inGivenDims, inExpectedDims);
//     then
//       {};
//
//   case(dim1::dims1, _)
//     equation
//       true = listLength(inGivenDims) > listLength(inExpectedDims);
//       dims1 = findVectorizationDim(dims1,inExpectedDims);
//     then
//       dim1::dims1;
//
//   case(_::_, _)
//     equation
//        assert(false, getInstanceName() + " failed.");
//       /* with dimensions: [" +
//        ExpressionDump.printListStr(inGivenDims,ExpressionDump.dimensionString,",") + "] vs [" +
//        ExpressionDump.printListStr(inExpectedDims,ExpressionDump.dimensionString,",") + "].");
//        */
//     then
//       fail();
//
// end matchcontinue;
//
//end findVectorizationDim;
//
//protected function isSpecialBuiltinFunctionName
//"@author: adrpo
// check if the name is special builtin function or
// operator which does not have a definition in ModelicaBuiltin.mo
// TODO FIXME, add all of them"
//  input Absyn.ComponentRef functionName;
//  output Boolean isBuiltinFname;
//algorithm
//  isBuiltinFname := matchcontinue(functionName)
//    local
//      String name;
//      Boolean b, b1, b2;
//      Absyn.ComponentRef fname;
//
//    case (Absyn.CREF_FULLYQUALIFIED(fname))
//      then
//        isSpecialBuiltinFunctionName(fname);
//
//    case (Absyn.CREF_IDENT(name, {}))
//      equation
//        b1 = listMember(name, {"String", "Integer"});
//        // these are the new Modelica 3.3 synch operators
//        b2 = if intGe(Flags.getConfigEnum(Flags.LANGUAGE_STANDARD), 33)
//              then
//                listMember(name, {"Clock", "previous", "hold", "subSample", "superSample", "shiftSample",
//                                  "backSample", "noClock", "transition", "initialState", "activeState",
//                                  "ticksInState", "timeInState"})
//              else false;
//        b = boolOr(b1, b2);
//      then
//        b;
//
//    case (_) then false;
//  end matchcontinue;
//end isSpecialBuiltinFunctionName;
//
//protected function isBuiltinFunctionName
//"@author: adrpo
// check if the name is a builtin function or operator
// TODO FIXME, add all of them"
//  input Absyn.ComponentRef functionName;
//  output Boolean isBuiltinFname;
//algorithm
//  isBuiltinFname := matchcontinue(functionName)
//    local
//      String name;
//      Boolean b;
//      Absyn.ComponentRef fname;
//
//    case (Absyn.CREF_FULLYQUALIFIED(fname))
//      then
//        isBuiltinFunctionName(fname);
//
//    case (Absyn.CREF_IDENT(name, {}))
//      equation
//        b = listMember(name,
//          {
//            "noEvent",
//            "smooth",
//            "sample",
//            "pre",
//            "edge",
//            "change",
//            "reinit",
//            "size",
//            "rooted",
//            "transpose",
//            "skew",
//            "identity",
//            "min",
//            "max",
//            "cross",
//            "diagonal",
//            "abs",
//            "sum",
//            "product",
//            "assert",
//            "array",
//            "cat",
//            "rem",
//            "actualStream",
//            "inStream",
//            // TODO Clock
//            "previous",
//            "hold",
//            "subSample",
//            "superSample",
//            // TODO sample, shiftSample, backSample, noClock
//            "initialState",
//            "transition",
//            "activeState",
//            "ticksInState",
//            "timeInState"
//            });
//      then
//        b;
//
//    case (_) then false;
//  end matchcontinue;
//end isBuiltinFunctionName;
//
//// adrpo:
//// - see Static.mo for how to check the input arguments or any other checks we need that should be ported
//// - try to use Expression.makePureBuiltinCall everywhere instead of creating the typedExp via DAE.CALL
//// - this function should handle special builtin operators which are not defined in ModelicaBuiltin.mo
//protected function typeSpecialBuiltinFunctionCall
//"@author: adrpo
// handle all builtin calls that are not defined at all in ModelicaBuiltin.mo
// TODO FIXME, add all"
//  input Absyn.ComponentRef functionName;
//  input Absyn.FunctionArgs functionArgs;
//  input Prefix prefix;
//  input InstNode classNode;
//  input InstNode scope;
//  input SourceInfo info;
//  output Expression typedExp;
//  output Type ty;
//  output DAE.Const variability;
//protected
//   String fnName;
//   DAE.Const vr, vr1, vr2;
//algorithm
//  (typedExp, ty, variability) := match(functionName, functionArgs)
//    local
//      Absyn.ComponentRef acref;
//      Absyn.Exp aexp1, aexp2;
//      Expression dexp1, dexp2;
//      list<Absyn.Exp>  afargs;
//      list<Absyn.NamedArg> anamed_args;
//      Absyn.Path call_path;
//      list<Expression> pos_args, args;
//      list<tuple<String, Expression>> named_args;
//      list<InstNode> inputs, outputs;
//      Absyn.ForIterators iters;
//      DAE.Dimensions d1, d2;
//      Type el_ty;
//      list<Type> tys;
//      list<DAE.Const> vrs;
//
//    // TODO FIXME: String might be overloaded, we need to handle this better! See Static.mo
//    case (Absyn.CREF_IDENT(name = "String"), Absyn.FUNCTIONARGS(args = afargs))
//      algorithm
//        call_path := Absyn.crefToPath(functionName);
//        (args,_, vrs) := Typing.typeExps(afargs, scope, info);
//        vr := List.fold(vrs, Types.constAnd, DAE.C_CONST());
//        ty := Type.STRING();
//      then
//        (Expression.CALL(call_path, Expression.CREF(classNode, prefix), args, NFExpression.callAttrBuiltinOther), ty, vr);
//
//    // TODO FIXME: check that the input is an enumeration
//    case (Absyn.CREF_IDENT(name = "Integer"), Absyn.FUNCTIONARGS(args = afargs))
//      algorithm
//        call_path := Absyn.crefToPath(functionName);
//        (args,_, vrs) := Typing.typeExps(afargs, scope, info);
//        vr := List.fold(vrs, Types.constAnd, DAE.C_CONST());
//        ty := Type.INTEGER();
//      then
//        (Expression.CALL(call_path, Expression.CREF(classNode, prefix), args, NFExpression.callAttrBuiltinOther), ty, vr);
//
//    // TODO FIXME! handle all the Modelica 3.3 operators here, see isSpecialBuiltinFunctionName
//
// end match;
//end typeSpecialBuiltinFunctionCall;
//
//
//// adrpo:
//// - see Static.mo for how to check the input arguments or any other checks we need that should be ported
//// - try to use Expression.makePureBuiltinCall everywhere instead of creating the typedExp via DAE.CALL
//// - all the fuctions that are defined *with no input/output type* in ModelicaBuiltin.mo such as:
////     function NAME "Transpose a matrix"
////       external "builtin";
////     end NAME;
////   need to be handled here!
//// - the functions which have a type in the ModelicaBuiltin.mo should be handled by the last case in this function
//protected function typeBuiltinFunctionCall
//"@author: adrpo
// handle all builtin calls that are not in ModelicaBuiltin.mo
// TODO FIXME, add all"
//  input Absyn.ComponentRef functionName;
//  input Absyn.FunctionArgs functionArgs;
//  input Prefix prefix;
//  input InstNode classNode;
//  input Type classType;
//  input SCode.Element cls;
//  input InstNode scope;
//  input SourceInfo info;
//  output Expression typedExp;
//  output Type ty;
//  output DAE.Const variability;
//protected
//   String fnName;
//   DAE.Const vr, vr1, vr2;
//algorithm
//  (typedExp, ty, variability) := matchcontinue(functionName, functionArgs)
//    local
//      Absyn.ComponentRef acref;
//      Absyn.Exp aexp1, aexp2;
//      Expression dexp1, dexp2;
//      list<Absyn.Exp>  afargs;
//      list<Absyn.NamedArg> anamed_args;
//      Absyn.Path call_path;
//      list<Expression> pos_args, args;
//      list<tuple<String, Expression>> named_args;
//      list<InstNode> inputs, outputs;
//      Absyn.ForIterators iters;
//      Dimension d1, d2;
//      Type el_ty, ty1, ty2;
//
//    // size(arr, dim)
//    case (Absyn.CREF_IDENT(name = "size"), Absyn.FUNCTIONARGS(args = {aexp1, aexp2}))
//      algorithm
//        (dexp1,_, vr1) := Typing.typeExp(aexp1, scope, info);
//        (dexp2,_, vr2) := Typing.typeExp(aexp2, scope, info);
//
//        // TODO FIXME: calculate the correct type and the correct variability, see Static.elabBuiltinSize in Static.mo
//        ty := Type.INTEGER();
//        // the variability does not actually depend on the variability of "arr" but on the variability of the dimensions of "arr"
//        vr := Types.constAnd(vr1, vr2);
//      then
//        (Expression.SIZE(dexp1, SOME(dexp2)), ty, vr);
//
//    // size(arr)
//    case (Absyn.CREF_IDENT(name = "size"), Absyn.FUNCTIONARGS(args = {aexp1}))
//      algorithm
//        (dexp1,_, vr1) := Typing.typeExp(aexp1, scope, info);
//        // TODO FIXME: calculate the correct type and the correct variability, see Static.elabBuiltinSize in Static.mo
//        ty := Type.INTEGER();
//        // the variability does not actually depend on the variability of "arr" but on the variability of the dimensions of "arr"
//        vr := vr1;
//      then
//        (Expression.SIZE(dexp1, NONE()), ty, vr);
//
//    case (Absyn.CREF_IDENT(name = "smooth"), Absyn.FUNCTIONARGS(args = {aexp1, aexp2}))
//      algorithm
//        call_path := Absyn.crefToPath(functionName);
//        (dexp1,_, vr1) := Typing.typeExp(aexp1, scope, info);
//        (dexp2,_, vr2) := Typing.typeExp(aexp2, scope, info);
//
//        // TODO FIXME: calculate the correct type and the correct variability, see Static.mo
//        ty := Type.REAL();
//        vr := vr1;
//      then
//        (Expression.CALL(call_path, Expression.CREF(classNode, prefix), {dexp1,dexp2}, NFExpression.callAttrBuiltinOther), ty, vr);
//
//    case (Absyn.CREF_IDENT(name = "rooted"), Absyn.FUNCTIONARGS(args = {aexp1}))
//      algorithm
//        call_path := Absyn.crefToPath(functionName);
//        (dexp1,_, vr1) := Typing.typeExp(aexp1, scope, info);
//
//        // TODO FIXME: calculate the correct type and the correct variability, see Static.mo
//        ty := Type.BOOLEAN();
//        vr := vr1;
//      then
//        (Expression.CALL(call_path, Expression.CREF(classNode, prefix), {dexp1}, NFExpression.callAttrBuiltinOther), ty, vr);
//
//    case (Absyn.CREF_IDENT(name = "transpose"), Absyn.FUNCTIONARGS(args = {aexp1}))
//      algorithm
//        (dexp1, ty1, vr1) := Typing.typeExp(aexp1, scope, info);
//
//        // transpose the type.
//        Type.ARRAY(elementType = el_ty, dimensions = {d1, d2}) := ty1;
//        ty := Type.ARRAY(el_ty, {d2, d1});
//
//        // create the typed transpose expression
//        typedExp := Expression.makePureBuiltinCall("transpose", Expression.CREF(classNode, prefix), {dexp1}, ty);
//        vr := vr1;
//      then
//        (typedExp, ty, vr);
//
//    // min|max(arr)
//    case (Absyn.CREF_IDENT(name = fnName), Absyn.FUNCTIONARGS(args = {aexp1}))
//      algorithm
//        true := listMember(fnName, {"min", "max"});
//        (dexp1, ty1, vr1) := Typing.typeExp(aexp1, scope, info);
//
//        true := Type.isArray(ty1);
//        //dexp1 := Expression.matrixToArray(dexp1);
//        el_ty := Type.arrayElementType(ty1);
//        false := Type.isString(el_ty);
//
//        ty := el_ty;
//        vr := vr1;
//        typedExp := Expression.makePureBuiltinCall(fnName, Expression.CREF(classNode, prefix), {dexp1}, ty);
//      then
//        (typedExp, ty, vr);
//
//    // min|max(x,y) where x & y are scalars.
//    case (Absyn.CREF_IDENT(name = fnName), Absyn.FUNCTIONARGS(args = {aexp1, aexp2}))
//      algorithm
//        true := listMember(fnName, {"min", "max"});
//        (dexp1, ty1, vr1) := Typing.typeExp(aexp1, scope, info);
//        (dexp2, ty2, vr2) := Typing.typeExp(aexp2, scope, info);
//
//        ty := Type.scalarSuperType(ty1, ty2);
//        //(dexp1, _) := Types.matchType(dexp1, ty1, ty, true);
//        //(dexp2, _) := Types.matchType(dexp2, ty2, ty, true);
//        vr := Types.constAnd(vr1, vr2);
//        false := Type.isString(ty);
//        typedExp := Expression.makePureBuiltinCall(fnName, Expression.CREF(classNode, prefix), {dexp1, dexp2}, ty);
//      then
//        (typedExp, ty, vr);
//
//    case (Absyn.CREF_IDENT(name = "diagonal"), Absyn.FUNCTIONARGS(args = aexp1::_))
//      algorithm
//        (dexp1, ty1, vr1) := Typing.typeExp(aexp1, scope, info);
//        Type.ARRAY(elementType = el_ty, dimensions = {d1}) := ty1;
//        ty := Type.ARRAY(el_ty, {d1, d1});
//        typedExp := Expression.makePureBuiltinCall("diagonal", Expression.CREF(classNode, prefix), {dexp1}, ty);
//        vr := vr1;
//      then
//        (typedExp, ty, vr);
//
//    case (Absyn.CREF_IDENT(name = "pre"), Absyn.FUNCTIONARGS(args = {aexp1}))
//      algorithm
//        (dexp1, ty, vr) := Typing.typeExp(aexp1, scope, info);
//
//        // create the typed call
//        typedExp := Expression.makePureBuiltinCall("pre", Expression.CREF(classNode, prefix), {dexp1}, ty);
//      then
//        (typedExp, ty, vr);
//
//    case (Absyn.CREF_IDENT(name = "previous"), Absyn.FUNCTIONARGS(args = {aexp1}))
//      guard intGe(Flags.getConfigEnum(Flags.LANGUAGE_STANDARD), 33)
//      algorithm
//        // TODO? Check that aexp1 is a Component Expression (MLS 3.3, Section 16.2.3) or parameter expression
//        (dexp1, ty, vr) := Typing.typeExp(aexp1, scope, info);
//        // create the typed call
//        typedExp := Expression.makeBuiltinCall("previous", Expression.CREF(classNode, prefix), {dexp1}, ty, true);
//      then
//        (typedExp, ty, vr);
//
//    case (Absyn.CREF_IDENT(name = "hold"), Absyn.FUNCTIONARGS(args = {aexp1}))
//      guard intGe(Flags.getConfigEnum(Flags.LANGUAGE_STANDARD), 33)
//      algorithm
//        // TODO? Check that aexp1 is a Component Expression (MLS 3.3, Section 16.2.3) or parameter expression
//        (dexp1, ty, vr) := Typing.typeExp(aexp1, scope, info);
//        // create the typed call
//        typedExp := Expression.makeBuiltinCall("hold", Expression.CREF(classNode, prefix), {dexp1}, ty, true);
//      then
//        (typedExp, ty, vr);
//
//    // subSample(u)/superSample(u), subSample(u, factor)/superSample(u, factor)
//    case (Absyn.CREF_IDENT(name = fnName), Absyn.FUNCTIONARGS(args = afargs))
//      guard intGe(Flags.getConfigEnum(Flags.LANGUAGE_STANDARD), 33) and
//        listMember(fnName, {"subSample", "superSample"}) and
//          (listLength(afargs) == 1 or listLength(afargs) == 2)
//      algorithm
//        if listLength(afargs) == 1 then
//          aexp1 := listHead(afargs);
//          // Create default argument factor=0
//          dexp2 := Expression.INTEGER(0);
//        else
//          {aexp1, aexp2} := afargs;
//          (dexp2, ty2, vr2) := Typing.typeExp(aexp2, scope, info);
//          Type.INTEGER() := ty2;
//          // TODO FIXME  check if vr2 is a parameter expressions
//          // TODO FIXME (evaluate) and check if factor >= 0
//        end if;
//        (dexp1, ty, vr) := Typing.typeExp(aexp1, scope, info);
//
//        // create the typed call
//        typedExp := Expression.makeBuiltinCall(fnName, Expression.CREF(classNode, prefix), {dexp1, dexp2}, ty, true);
//      then
//        (typedExp, ty, vr);
//
//    // initialState(state)
//    case (Absyn.CREF_IDENT(name = "initialState"), Absyn.FUNCTIONARGS(args = {aexp1}))
//      guard intGe(Flags.getConfigEnum(Flags.LANGUAGE_STANDARD), 33)
//      algorithm
//        (dexp1, ty1, vr) := Typing.typeExp(aexp1, scope, info);
//
//        // MLS 3.3 requires a 'block' instance as argument aexp1.
//        // Checking here for 'complex' types is too broad, but convenient
//        Error.assertionOrAddSourceMessage(Type.isComplex(ty1),Error.WRONG_TYPE_OR_NO_OF_ARGS,
//            {"initialState(" + Expression.toString(dexp1) + "), Argument needs to be a block instance.",
//            Absyn.pathString(InstNode.path(scope))}, info);
//
//        ty := Type.NORETCALL();
//
//        // create the typed call
//        typedExp := Expression.makeBuiltinCall("initialState", Expression.CREF(classNode, prefix), {dexp1}, ty, true);
//      then
//        (typedExp, ty, vr);
//
//    // transition(from, to, condition, immediate=true, reset=true, synchronize=false, priority=1)
//    case (Absyn.CREF_IDENT(name = "transition"), _)
//      guard intGe(Flags.getConfigEnum(Flags.LANGUAGE_STANDARD), 33)
//      then
//        elabBuiltinTransition(functionName, functionArgs, prefix, classNode, classType, cls, scope, info);
//
//    // activeState(state)
//    case (Absyn.CREF_IDENT(name = "activeState"), Absyn.FUNCTIONARGS(args = {aexp1}))
//      guard intGe(Flags.getConfigEnum(Flags.LANGUAGE_STANDARD), 33)
//      algorithm
//        (dexp1, ty1, vr) := Typing.typeExp(aexp1, scope, info);
//
//        // MLS 3.3 requires a 'block' instance as argument aexp1.
//        // Checking here for 'complex' types is too broad, but convenient
//        Error.assertionOrAddSourceMessage(Type.isComplex(ty1),Error.WRONG_TYPE_OR_NO_OF_ARGS,
//            {"activeState(" + Expression.toString(dexp1) + "), Argument needs to be a block instance.",
//            Absyn.pathString(InstNode.path(scope))}, info);
//
//        ty := Type.BOOLEAN();
//
//        // create the typed call
//        typedExp := Expression.makeBuiltinCall("activeState", Expression.CREF(classNode, prefix), {dexp1}, ty, true);
//      then
//        (typedExp, ty, vr);
//
//    // ticksInState()
//    case (Absyn.CREF_IDENT(name = "ticksInState"), Absyn.FUNCTIONARGS(args = {}))
//      guard intGe(Flags.getConfigEnum(Flags.LANGUAGE_STANDARD), 33)
//      algorithm
//        ty := Type.INTEGER();
//        vr := DAE.C_VAR();
//        // create the typed call
//        typedExp := Expression.makeBuiltinCall("ticksInState", Expression.CREF(classNode, prefix), {}, ty, true);
//      then
//        (typedExp, ty, vr);
//
//    // timeInState()
//    case (Absyn.CREF_IDENT(name = "timeInState"), Absyn.FUNCTIONARGS(args = {}))
//      guard intGe(Flags.getConfigEnum(Flags.LANGUAGE_STANDARD), 33)
//      algorithm
//        ty := Type.REAL();
//        vr := DAE.C_VAR();
//        // create the typed call
//        typedExp := Expression.makeBuiltinCall("timeInState", Expression.CREF(classNode, prefix), {}, ty, true);
//      then
//        (typedExp, ty, vr);
//
//
//
//    /* adrpo: adapt these to the new structures, see above
//    case (Absyn.CREF_IDENT(name = "product"), Absyn.FUNCTIONARGS(args = afargs))
//      equation
//        call_path = Absyn.crefToPath(functionName);
//        (pos_args, globals) = Typing.typeExps(afargs, inEnv, inPrefix, inInfo, globals);
//      then
//        DAE.CALL(call_path, pos_args, NFExpression.callAttrBuiltinOther);
//
//    case (Absyn.CREF_IDENT(name = "pre"), Absyn.FUNCTIONARGS(args = afargs))
//      equation
//        call_path = Absyn.crefToPath(functionName);
//        (pos_args, globals) = Typing.typeExps(afargs, inEnv, inPrefix, inInfo, globals);
//      then
//        DAE.CALL(call_path, pos_args, NFExpression.callAttrBuiltinOther);
//
//    case (Absyn.CREF_IDENT(name = "noEvent"), Absyn.FUNCTIONARGS(args = afargs))
//      equation
//        call_path = Absyn.crefToPath(functionName);
//        (pos_args, globals) = Typing.typeExps(afargs, inEnv, inPrefix, inInfo, globals);
//      then
//        DAE.CALL(call_path, pos_args, NFExpression.callAttrBuiltinOther);
//
//    case (Absyn.CREF_IDENT(name = "sum"), Absyn.FUNCTIONARGS(args = afargs))
//      equation
//        call_path = Absyn.crefToPath(functionName);
//        (pos_args, globals) = Typing.typeExps(afargs, inEnv, inPrefix, inInfo, globals);
//      then
//        DAE.CALL(call_path, pos_args, NFExpression.callAttrBuiltinOther);
//
//    case (Absyn.CREF_IDENT(name = "assert"), Absyn.FUNCTIONARGS(args = afargs))
//      equation
//        call_path = Absyn.crefToPath(functionName);
//        (pos_args, globals) = Typing.typeExps(afargs, inEnv, inPrefix, inInfo, globals);
//      then
//        DAE.CALL(call_path, pos_args, NFExpression.callAttrBuiltinOther);
//
//    case (Absyn.CREF_IDENT(name = "change"), Absyn.FUNCTIONARGS(args = afargs))
//      equation
//        call_path = Absyn.crefToPath(functionName);
//        (pos_args, globals) = Typing.typeExps(afargs, inEnv, inPrefix, inInfo, globals);
//      then
//        DAE.CALL(call_path, pos_args, NFExpression.callAttrBuiltinOther);
//
//    case (Absyn.CREF_IDENT(name = "array"), Absyn.FUNCTIONARGS(args = afargs))
//      equation
//        call_path = Absyn.crefToPath(functionName);
//        (pos_args, globals) = Typing.typeExps(afargs, inEnv, inPrefix, inInfo, globals);
//      then
//        DAE.CALL(call_path, pos_args, NFExpression.callAttrBuiltinOther);
//
//    case (Absyn.CREF_IDENT(name = "array"), Absyn.FOR_ITER_FARG(exp=aexp1, iterators=iters))
//      equation
//        call_path = Absyn.crefToPath(functionName);
//        env = NFSCodeEnv.extendEnvWithIterators(iters, System.tmpTickIndex(NFSCodeEnv.tmpTickIndex), inEnv);
//        (dexp1, globals) = Typing.typeExp(aexp1, env, inPrefix, inInfo, globals);
//      then
//        DAE.CALL(call_path, {dexp1}, NFExpression.callAttrBuiltinOther);
//
//    case (Absyn.CREF_IDENT(name = "sum"), Absyn.FOR_ITER_FARG(exp=aexp1, iterators=iters))
//      equation
//        call_path = Absyn.crefToPath(functionName);
//        env = NFSCodeEnv.extendEnvWithIterators(iters, System.tmpTickIndex(NFSCodeEnv.tmpTickIndex), inEnv);
//        (dexp1, globals) = Typing.typeExp(aexp1, env, inPrefix, inInfo, globals);
//      then
//        DAE.CALL(call_path, {dexp1}, NFExpression.callAttrBuiltinOther);
//
//    case (Absyn.CREF_IDENT(name = "min"), Absyn.FOR_ITER_FARG(exp=aexp1, iterators=iters))
//      equation
//        call_path = Absyn.crefToPath(functionName);
//        env = NFSCodeEnv.extendEnvWithIterators(iters, System.tmpTickIndex(NFSCodeEnv.tmpTickIndex), inEnv);
//        (dexp1, globals) = Typing.typeExp(aexp1, env, inPrefix, inInfo, globals);
//      then
//        DAE.CALL(call_path, {dexp1}, NFExpression.callAttrBuiltinOther);
//
//    case (Absyn.CREF_IDENT(name = "max"), Absyn.FOR_ITER_FARG(exp=aexp1, iterators=iters))
//      equation
//        call_path = Absyn.crefToPath(functionName);
//        env = NFSCodeEnv.extendEnvWithIterators(iters, System.tmpTickIndex(NFSCodeEnv.tmpTickIndex), inEnv);
//        (dexp1, globals) = Typing.typeExp(aexp1, env, inPrefix, inInfo, globals);
//      then
//        DAE.CALL(call_path, {dexp1}, NFExpression.callAttrBuiltinOther);
//
//    case (Absyn.CREF_IDENT(name = "product"), Absyn.FOR_ITER_FARG(exp=aexp1, iterators=iters))
//      equation
//        call_path = Absyn.crefToPath(functionName);
//        env = NFSCodeEnv.extendEnvWithIterators(iters, System.tmpTickIndex(NFSCodeEnv.tmpTickIndex), inEnv);
//        (dexp1, globals) = Typing.typeExp(aexp1, env, inPrefix, inInfo, globals);
//      then
//        DAE.CALL(call_path, {dexp1}, NFExpression.callAttrBuiltinOther);
//
//    case (Absyn.CREF_IDENT(name = "cat"), Absyn.FUNCTIONARGS(args = afargs))
//      equation
//        call_path = Absyn.crefToPath(functionName);
//        (pos_args, globals) = Typing.typeExps(afargs, inEnv, inPrefix, inInfo, globals);
//      then
//        DAE.CALL(call_path, pos_args, NFExpression.callAttrBuiltinOther);
//
//    case (Absyn.CREF_IDENT(name = "actualStream"), Absyn.FUNCTIONARGS(args = afargs))
//      equation
//        call_path = Absyn.crefToPath(functionName);
//        (pos_args, globals) = Typing.typeExps(afargs, inEnv, inPrefix, inInfo, globals);
//      then
//        DAE.CALL(call_path, pos_args, NFExpression.callAttrBuiltinOther);
//
//    case (Absyn.CREF_IDENT(name = "inStream"), Absyn.FUNCTIONARGS(args = afargs))
//      equation
//        call_path = Absyn.crefToPath(functionName);
//        (pos_args, globals) = Typing.typeExps(afargs, inEnv, inPrefix, inInfo, globals);
//      then
//        DAE.CALL(call_path, pos_args, NFExpression.callAttrBuiltinOther);
//
//    case (Absyn.CREF_IDENT(name = "String"), Absyn.FUNCTIONARGS(args = afargs))
//      equation
//        call_path = Absyn.crefToPath(functionName);
//        (pos_args, globals) = Typing.typeExps(afargs, inEnv, inPrefix, inInfo, globals);
//      then
//        DAE.CALL(call_path, pos_args, NFExpression.callAttrBuiltinOther);
//
//    case (Absyn.CREF_IDENT(name = "Integer"), Absyn.FUNCTIONARGS(args = afargs))
//      equation
//        call_path = Absyn.crefToPath(functionName);
//        (pos_args, globals) = Typing.typeExps(afargs, inEnv, inPrefix, inInfo, globals);
//      then
//        DAE.CALL(call_path, pos_args, NFExpression.callAttrBuiltinOther);
//
//    case (Absyn.CREF_IDENT(name = "Real"), Absyn.FUNCTIONARGS(args = afargs))
//      equation
//        call_path = Absyn.crefToPath(functionName);
//        (pos_args, globals) = Typing.typeExps(afargs, inEnv, inPrefix, inInfo, globals);
//      then
//        DAE.CALL(call_path, pos_args, NFExpression.callAttrBuiltinOther);
//    */
//
//    // TODO! FIXME!
//    // check if more functions need to be handled here
//    // we also need to handle Absyn.FOR_ITER_FARG reductions instead of Absyn.FUNCTIONARGS
//
//    /*
//    // adrpo: no support for $overload functions yet: div, mod, rem, abs, i.e. ModelicaBuiltin.mo:
//    // function mod = $overload(OpenModelica.Internal.intMod,OpenModelica.Internal.realMod)
//    case (Absyn.CREF_IDENT(name = "rem"), Absyn.FUNCTIONARGS(args = afargs))
//      equation
//        call_path = Absyn.crefToPath(functionName);
//        (pos_args, globals) = Typing.typeExps(afargs, inEnv, inPrefix, inInfo, globals);
//      then
//        DAE.CALL(call_path, pos_args, NFExpression.callAttrBuiltinOther);
//
//    case (Absyn.CREF_IDENT(name = "abs"), Absyn.FUNCTIONARGS(args = afargs))
//      equation
//        call_path = Absyn.crefToPath(functionName);
//        (pos_args, globals) = Typing.typeExps(afargs, inEnv, inPrefix, inInfo, globals);
//      then
//        DAE.CALL(call_path, pos_args, NFExpression.callAttrBuiltinOther);
//    */
//
//    // hopefully all the other ones have a complete entry in ModelicaBuiltin.mo
//    case (_, _)
//      algorithm
//        (typedExp, ty, vr) := typeNormalFunction(functionName, functionArgs, prefix, classNode, classType, scope, info);
//      then
//        (typedExp, ty, vr);
//
// end matchcontinue;
//end typeBuiltinFunctionCall;
//
//
//protected function elabBuiltinTransition
//"elaborate the builtin operator
// transition(from, to, condition, immediate=true, reset=true, synchronize=false, priority=1)"
//  input Absyn.ComponentRef functionName;
//  input Absyn.FunctionArgs functionArgs;
//  input Prefix prefix;
//  input InstNode classNode;
//  input Type classType;
//  input SCode.Element cls;
//  input InstNode scope;
//  input SourceInfo info;
//  output Expression typedExp;
//  output Type ty;
//  output DAE.Const variability;
//protected
//  list<Absyn.Exp>  afargs;
//  list<Absyn.NamedArg> anamed_args;
//  Absyn.Ident argName;
//  Absyn.Exp argValue;
//  array<Absyn.Exp> argExps = listArray({Absyn.STRING("from_NoDefault"), Absyn.STRING("to_NoDefault"),  Absyn.STRING("condition_NoDefault"), Absyn.BOOL(true), Absyn.BOOL(true), Absyn.BOOL(false), Absyn.INTEGER(1)});
//  array<Absyn.Exp> afargsArray;
//  Expression dexp1, dexp2, dexp3, dexp4, dexp5, dexp6, dexp7;
//  Type ty1, ty2, ty3, ty4, ty5, ty6, ty7;
//  DAE.Const vr1, vr2, vr3, vr4, vr5, vr6, vr7;
//  String str;
//  Integer afargsLen;
//algorithm
//  Absyn.FUNCTIONARGS(args=afargs, argNames=anamed_args) := functionArgs;
//  afargsArray := listArray(afargs);
//  afargsLen := listLength(afargs);
//
//  for i in 1:afargsLen loop
//    argExps := arrayUpdate(argExps, i, arrayGet(afargsArray,i));
//  end for;
//
//  for anamed in anamed_args loop
//    Absyn.NAMEDARG(argName, argValue) := anamed;
//    if argName == "from" and afargsLen < 1 then arrayUpdate(argExps, 1, argValue);
//    elseif argName == "to" and afargsLen < 2 then arrayUpdate(argExps, 2, argValue);
//    elseif argName == "condition" and afargsLen < 3 then arrayUpdate(argExps, 3, argValue);
//    elseif argName == "immediate" and afargsLen < 4 then arrayUpdate(argExps, 4, argValue);
//    elseif argName == "reset" and afargsLen < 5 then arrayUpdate(argExps, 5, argValue);
//    elseif argName == "synchronize" and afargsLen < 6 then arrayUpdate(argExps, 6, argValue);
//    elseif argName == "priority" and afargsLen < 7 then arrayUpdate(argExps, 7, argValue);
//    else
//      Error.addSourceMessageAndFail(Error.NO_SUCH_ARGUMENT,
//      {"transition(" + argName + "=" + Dump.dumpExpStr(argValue) + "), no such argument or conflict with unnamed arguments",
//        Absyn.pathString(InstNode.path(scope))}, info);
//    end if;
//  end for;
//
//  // check if first 3 mandatory arguments have been provided
//  for i in 1:3 loop
//    () := match arrayGet(argExps, i)
//      case Absyn.STRING(str)
//        algorithm
//          Error.addSourceMessageAndFail(Error.WRONG_TYPE_OR_NO_OF_ARGS,
//              {"transition(from, to, condition, immediate=true, reset=true, synchronize=false, priority=1), missing " + intString(i) + ". argument",
//              Absyn.pathString(InstNode.path(scope))}, info);
//        then fail();
//      else then ();
//    end match;
//  end for;
//
//  (dexp1, ty1, vr1) := Typing.typeExp(arrayGet(argExps,1), scope, info);
//  (dexp2, ty2, vr2) := Typing.typeExp(arrayGet(argExps,2), scope, info);
//  // MLS 3.3 requires a 'block' instances as argument 1 and 2.
//  // Checking here for 'complex' types is too broad, but convenient
//  Error.assertionOrAddSourceMessage(Type.isComplex(ty1),Error.WRONG_TYPE_OR_NO_OF_ARGS,
//    {"transition(" + Expression.toString(dexp1) + ", ...), Argument needs to be a block instance.",
//      Absyn.pathString(InstNode.path(scope))}, info);
//  Error.assertionOrAddSourceMessage(Type.isComplex(ty2),Error.WRONG_TYPE_OR_NO_OF_ARGS,
//    {"transition(..., " + Expression.toString(dexp2) + ", ...), Argument needs to be a block instance.",
//      Absyn.pathString(InstNode.path(scope))}, info);
//
//    // TODO check that variability of arguments below are parameter or constant
//
//  (dexp3, ty3, vr3) := Typing.typeExp(arrayGet(argExps,3), scope, info);
//  Error.assertionOrAddSourceMessage(Type.isBoolean(ty3),Error.WRONG_TYPE_OR_NO_OF_ARGS,
//    {"transition(..., " + Expression.toString(dexp3) + ", ...), Argument needs to be of type Boolean.",
//      Absyn.pathString(InstNode.path(scope))}, info);
//
//  (dexp4, ty4, vr4) := Typing.typeExp(arrayGet(argExps,4), scope, info);
//  Error.assertionOrAddSourceMessage(Type.isBoolean(ty4),Error.WRONG_TYPE_OR_NO_OF_ARGS,
//    {"transition(..., " + Expression.toString(dexp4) + ", ...), Argument needs to be of type Boolean.",
//      Absyn.pathString(InstNode.path(scope))}, info);
//
//  // Error.assertionOrAddSourceMessage(Types.isParameterOrConstant(vr4),Error.WRONG_TYPE_OR_NO_OF_ARGS,
//  //   {"transition(..., " + Expression.toString(dexp4) + ", ...), Argument needs to be of type Boolean.",
//  //     Absyn.pathString(InstNode.path(scope))}, info);
//
//  (dexp5, ty5, vr5) := Typing.typeExp(arrayGet(argExps,5), scope, info);
//  Error.assertionOrAddSourceMessage(Type.isBoolean(ty5),Error.WRONG_TYPE_OR_NO_OF_ARGS,
//    {"transition(..., " + Expression.toString(dexp5) + ", ...), Argument needs to be of type Boolean.",
//      Absyn.pathString(InstNode.path(scope))}, info);
//
//  (dexp6, ty6, vr6) := Typing.typeExp(arrayGet(argExps,6), scope, info);
//  Error.assertionOrAddSourceMessage(Type.isBoolean(ty6),Error.WRONG_TYPE_OR_NO_OF_ARGS,
//    {"transition(..., " + Expression.toString(dexp6) + ", ...), Argument needs to be of type Boolean.",
//      Absyn.pathString(InstNode.path(scope))}, info);
//
//  (dexp7, ty7, vr7) := Typing.typeExp(arrayGet(argExps,7), scope, info);
//  // TODO check that "priority" argument is >= 1
//  Error.assertionOrAddSourceMessage(Type.isInteger(ty7),Error.WRONG_TYPE_OR_NO_OF_ARGS,
//    {"transition(..., " + Expression.toString(dexp7) + ", ...), Argument needs to be of type Integer.",
//      Absyn.pathString(InstNode.path(scope))}, info);
//
//
//  ty := Type.NORETCALL();
//  // create the typed call
//  typedExp := Expression.makeBuiltinCall("transition", Expression.CREF(classNode, prefix), {dexp1, dexp2, dexp3, dexp4, dexp5, dexp6, dexp7}, ty, true);
//  variability := DAE.C_UNKNOWN();
//end elabBuiltinTransition;
//
//
//function getFunctionAttributes
//  input InstNode funcNode;
//  output DAE.FunctionAttributes attr;
//protected
//  SCode.Element def;
//  array<InstNode> params;
//  SCode.Restriction res;
//  SCode.FunctionRestriction fres;
//algorithm
//  def := InstNode.definition(funcNode);
//  res := SCode.getClassRestriction(def);
//
//  assert(SCode.isFunctionRestriction(res),
//    getInstanceName() + " got non-function restriction");
//  assert(InstNode.isClass(funcNode),
//    getInstanceName() + " got non-class node");
//
//  SCode.Restriction.R_FUNCTION(functionRestriction = fres) := res;
//  Class.INSTANCED_CLASS(components = params) := InstNode.getClass(funcNode);
//
//  attr := matchcontinue fres
//    local
//      Boolean is_impure, is_om_pure, has_out_params;
//      String name;
//      list<String> in_params, out_params;
//      DAE.InlineType inline_ty;
//      DAE.FunctionBuiltin builtin;
//
//    case SCode.FunctionRestriction.FR_EXTERNAL_FUNCTION(is_impure)
//      algorithm
//        in_params := list(InstNode.name(p) for p guard InstNode.isInput(p) in params);
//        out_params := list(InstNode.name(p) for p guard InstNode.isOutput(p) in params);
//        name := SCode.isBuiltinFunction(def, in_params, out_params);
//        inline_ty := InstUtil.isInlineFunc(def);
//        is_om_pure := not SCode.hasBooleanNamedAnnotationInClass(def, "__OpenModelica_Impure");
//        is_impure := if is_impure then true else SCode.hasBooleanNamedAnnotationInClass(def, "__ModelicaAssociation_Impure");
//      then
//        DAE.FUNCTION_ATTRIBUTES(inline_ty, is_om_pure, is_impure, false,
//          DAE.FUNCTION_BUILTIN(SOME(name), SCode.hasBooleanNamedAnnotationInClass(def, "__OpenModelica_UnboxArguments")), DAE.FP_NON_PARALLEL());
//
//    // Parallel function: there are some builtin functions.
//    case SCode.FunctionRestriction.FR_PARALLEL_FUNCTION()
//      algorithm
//        in_params := list(InstNode.name(p) for p guard InstNode.isInput(p) in params);
//        out_params := list(InstNode.name(p) for p guard InstNode.isOutput(p) in params);
//        name := SCode.isBuiltinFunction(def, in_params, out_params);
//        inline_ty := InstUtil.isInlineFunc(def);
//        is_om_pure := not SCode.hasBooleanNamedAnnotationInClass(def, "__OpenModelica_Impure");
//      then
//        DAE.FUNCTION_ATTRIBUTES(inline_ty, is_om_pure, false, false,
//          DAE.FUNCTION_BUILTIN(SOME(name), SCode.hasBooleanNamedAnnotationInClass(def, "__OpenModelica_UnboxArguments")), DAE.FP_PARALLEL_FUNCTION());
//
//    // Parallel function: non-builtin.
//    case SCode.FunctionRestriction.FR_PARALLEL_FUNCTION()
//      algorithm
//        inline_ty := InstUtil.isInlineFunc(def);
//        builtin := if SCode.hasBooleanNamedAnnotationInClass(def, "__OpenModelica_BuiltinPtr") then
//          DAE.FUNCTION_BUILTIN_PTR() else DAE.FUNCTION_NOT_BUILTIN();
//        is_om_pure := not SCode.hasBooleanNamedAnnotationInClass(def, "__OpenModelica_Impure");
//      then
//        DAE.FUNCTION_ATTRIBUTES(inline_ty, is_om_pure, false, false,
//          builtin, DAE.FP_PARALLEL_FUNCTION());
//
//    // Kernel functions: never builtin and never inlined.
//    case SCode.FunctionRestriction.FR_KERNEL_FUNCTION()
//      then DAE.FUNCTION_ATTRIBUTES(DAE.NO_INLINE(), true, false, false,
//        DAE.FUNCTION_NOT_BUILTIN(), DAE.FP_KERNEL_FUNCTION());
//
//    else
//      algorithm
//        inline_ty := InstUtil.isInlineFunc(def);
//        builtin := if SCode.hasBooleanNamedAnnotationInClass(def, "__OpenModelica_BuiltinPtr") then
//          DAE.FUNCTION_BUILTIN_PTR() else DAE.FUNCTION_NOT_BUILTIN();
//        is_om_pure := not SCode.hasBooleanNamedAnnotationInClass(def, "__OpenModelica_Impure");
//
//        // In Modelica 3.2 and before, external functions with side-effects are not marked.
//        is_impure := SCode.isRestrictionImpure(res,
//            Config.languageStandardAtLeast(Config.LanguageStandard.'3.3') or
//            Array.exist(params, InstNode.isOutput)) or
//          SCode.hasBooleanNamedAnnotationInClass(def, "__ModelicaAssociation_Impure");
//      then
//        DAE.FUNCTION_ATTRIBUTES(inline_ty, is_om_pure, is_impure, false,
//          builtin, DAE.FP_NON_PARALLEL());
//
//  end matchcontinue;
//end getFunctionAttributes;
//
//function makeFunctionType
//  input InstNode funcNode;
//  input DAE.FunctionAttributes attributes;
//  output Type funcType;
//protected
//  array<InstNode> params;
//  list<Component> in_params, out_params;
//  Type ret_ty;
//  Component c;
//algorithm
//  Class.INSTANCED_CLASS(components = params) := InstNode.getClass(funcNode);
//  in_params := list(InstNode.component(p) for p guard InstNode.isInput(p) in params);
//  out_params := list(InstNode.component(p) for p guard InstNode.isOutput(p) in params);
//
//  ret_ty := match out_params
//    case {} then Type.NORETCALL();
//    case {c} then Component.getType(c);
//    else
//      algorithm
//        assert(false, getInstanceName() + ": IMPLEMENT ME");
//      then
//        fail();
//  end match;
//
//  funcType := Type.FUNCTION(ret_ty, attributes);
//end makeFunctionType;
//
//function isBuiltinFunc
//  input Absyn.Path funcName;
//  input DAE.FunctionAttributes funcAttr;
//  output DAE.FunctionBuiltin builtin;
//  output Boolean isBuiltin;
//  output Absyn.Path newName;
//algorithm
//  (builtin, isBuiltin, newName) := matchcontinue (funcName, funcAttr)
//    local
//      String id;
//
//    case (_, DAE.FUNCTION_ATTRIBUTES(isBuiltin = builtin as DAE.FUNCTION_BUILTIN()))
//      then (builtin, true, Absyn.makeNotFullyQualified(funcName));
//
//    case (_, DAE.FUNCTION_ATTRIBUTES(isBuiltin = builtin as DAE.FUNCTION_BUILTIN_PTR()))
//      then (builtin, true, Absyn.makeNotFullyQualified(funcName));
//
//    case (Absyn.IDENT(name = id), _)
//      algorithm
//        Static.elabBuiltinHandler(id);
//      then
//        (DAE.FUNCTION_BUILTIN(SOME(id), false), true, funcName);
//
//    case (Absyn.QUALIFIED("OpenModelicaInternal", Absyn.IDENT(name = id)), _)
//      algorithm
//        Static.elabBuiltinHandlerInternal(id);
//      then
//        (DAE.FUNCTION_BUILTIN(SOME(id), false), true, funcName);
//
//    case (Absyn.FULLYQUALIFIED(), _)
//      algorithm
//        (builtin, isBuiltin, _) := isBuiltinFunc(funcName.path, funcAttr);
//      then
//        (builtin, isBuiltin, funcName.path);
//
//    case (Absyn.QUALIFIED("Connection", Absyn.IDENT("isRoot")), _)
//      then (DAE.FUNCTION_BUILTIN(NONE(), false), true, funcName);
//
//    else (DAE.FUNCTION_NOT_BUILTIN(), false, funcName);
//  end matchcontinue;
//end isBuiltinFunc;

annotation(__OpenModelica_Interface="frontend");
end NFFunc;
