require "./program"
require "./syntax/ast"
require "./syntax/visitor"
require "./semantic/*"

# The overall algorithm for semantic analysis of a program is:
# - top level: declare clases, modules, macros, defs and other top-level stuff
# - new methods: create `new` methods for every `initialize` method
# - type declarations: process type declarations like `@x : Int32`
# - check abstract defs: check that abstract defs are implemented
# - class_vars_initializers (ClassVarsInitializerVisitor): process initializers like `@@x = 1`
# - instance_vars_initializers (InstanceVarsInitializerVisitor): process initializers like `@x = 1`
# - main: process "main" code, calls and method bodies (the whole program).
# - cleanup: remove dead code and other simplifications
# - check recursive structs (RecursiveStructChecker): check that structs are not recursive (impossible to codegen)

module Crystal
  ThreadLocalAttributes      = %w(ThreadLocal)
  ValidGlobalAttributes      = ThreadLocalAttributes
  ValidExternalVarAttributes = ThreadLocalAttributes
  ValidClassVarAttributes    = ThreadLocalAttributes
  ValidStructDefAttributes   = %w(Packed)
  ValidDefAttributes         = %w(AlwaysInline Naked NoInline Raises ReturnsTwice Primitive)
  ValidFunDefAttributes      = %w(AlwaysInline Naked NoInline Raises ReturnsTwice CallConvention)
  ValidEnumDefAttributes     = %w(Flags)

  class Program
    # Runs semantic analysis on the given node, returning a node
    # that's typed. In the process types and methods are defined in
    # this program.
    def semantic(node : ASTNode, stats = false) : ASTNode
      node, processor = top_level_semantic(node, stats: stats)

      Crystal.timing("Semantic (cvars initializers)", stats) do
        visit_class_vars_initializers(node)
      end

      # Check that class vars without an initializer are nilable,
      # give an error otherwise
      processor.check_non_nilable_class_vars_without_initializers

      Crystal.timing("Semantic (ivars initializers)", stats) do
        node.accept InstanceVarsInitializerVisitor.new(self)
      end
      result = Crystal.timing("Semantic (main)", stats) do
        visit_main(node)
      end
      Crystal.timing("Semantic (cleanup)", stats) do
        cleanup_types
        cleanup_files
      end
      Crystal.timing("Semantic (recursive struct check)", stats) do
        RecursiveStructChecker.new(self).run
      end
      result
    end

    # Processes type declarations and instance/class/global vars
    # types are guessed or followed according to type annotations.
    #
    # This alone is useful for some tools like doc or hierarchy
    # where a full semantic of the program is not needed.
    def top_level_semantic(node, stats = false)
      Crystal.timing("Semantic (top level)", stats) do
        node.accept TopLevelVisitor.new(self)
      end
      Crystal.timing("Semantic (new)", stats) do
        define_new_methods
      end
      node, processor = Crystal.timing("Semantic (type declarations)", stats) do
        TypeDeclarationProcessor.new(self).process(node)
      end
      Crystal.timing("Semantic (abstract def check)", stats) do
        AbstractDefChecker.new(self).run
      end
      {node, processor}
    end
  end
end
