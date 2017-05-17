# encoding: utf-8
module Mongoid
  module Association
    module Referenced
      class HasAndBelongsToMany

        # This class defines the behaviour for all relations that are a
        # many-to-many between documents in different collections.
        class Proxy < Referenced::HasMany::Proxy

          # Appends a document or array of documents to the relation. Will set
          # the parent and update the index in the process.
          #
          # @example Append a document.
          #   person.posts << post
          #
          # @example Push a document.
          #   person.posts.push(post)
          #
          # @example Concat with other documents.
          #   person.posts.concat([ post_one, post_two ])
          #
          # @param [ Document, Array<Document> ] *args Any number of documents.
          #
          # @return [ Array<Document> ] The loaded docs.
          #
          # @since 2.0.0.beta.1
          def <<(*args)
            docs = args.flatten
            return concat(docs) if docs.size > 1
            if doc = docs.first
              append(doc)
              base.add_to_set(foreign_key => doc.send(__association.primary_key))
              if child_persistable?(doc)
                doc.save
              end
            end
            unsynced(base, foreign_key) and self
          end

          alias :push :<<

          # Appends an array of documents to the relation. Performs a batch
          # insert of the documents instead of persisting one at a time.
          #
          # @example Concat with other documents.
          #   person.posts.concat([ post_one, post_two ])
          #
          # @param [ Array<Document> ] documents The docs to add.
          #
          # @return [ Array<Document> ] The documents.
          #
          # @since 2.4.0
          def concat(documents)
            ids, docs, inserts = {}, [], []
            documents.each do |doc|
              next unless doc
              append(doc)
              if persistable? || _creating?
                ids[doc._id] = true
                save_or_delay(doc, docs, inserts)
              else
                existing = base.send(foreign_key)
                unless existing.include?(doc._id)
                  existing.push(doc._id) and unsynced(base, foreign_key)
                end
              end
            end
            if persistable? || _creating?
              base.push(foreign_key => ids.keys)
            end
            persist_delayed(docs, inserts)
            self
          end

          # Build a new document from the attributes and append it to this
          # relation without saving.
          #
          # @example Build a new document on the relation.
          #   person.posts.build(:title => "A new post")
          #
          # @overload build(attributes = {}, type = nil)
          #   @param [ Hash ] attributes The attributes of the new document.
          #   @param [ Class ] type The optional subclass to build.
          #
          # @overload build(attributes = {}, type = nil)
          #   @param [ Hash ] attributes The attributes of the new document.
          #   @param [ Class ] type The optional subclass to build.
          #
          # @return [ Document ] The new document.
          #
          # @since 2.0.0.beta.1
          def build(attributes = {}, type = nil)
            doc = Factory.build(type || klass, attributes)
            base.send(foreign_key).push(doc._id)
            append(doc)
            doc.apply_post_processed_defaults
            unsynced(doc, inverse_foreign_key)
            yield(doc) if block_given?
            doc
          end

          alias :new :build

          # Delete the document from the relation. This will set the foreign key
          # on the document to nil. If the dependent options on the relation are
          # :delete or :destroy the appropriate removal will occur.
          #
          # @example Delete the document.
          #   person.posts.delete(post)
          #
          # @param [ Document ] document The document to remove.
          #
          # @return [ Document ] The matching document.
          #
          # @since 2.1.0
          def delete(document)
            doc = super
            if doc && persistable?
              base.pull(foreign_key => doc.send(__association.primary_key))
              target._unloaded = criteria
              unsynced(base, foreign_key)
            end
            doc
          end

          # Removes all associations between the base document and the target
          # documents by deleting the foreign keys and the references, orphaning
          # the target documents in the process.
          #
          # @example Nullify the relation.
          #   person.preferences.nullify
          #
          # @since 2.0.0.rc.1
          def nullify(replacement = [])
            target.each do |doc|
              execute_callback :before_remove, doc
            end
            unless __association.forced_nil_inverse?
              if replacement
                objects_to_clear = base.send(foreign_key) - replacement.collect(&:id)
                criteria(objects_to_clear).pull(inverse_foreign_key => base._id)
              else
                criteria.pull(inverse_foreign_key => base._id)
              end
            end
            if persistable?
              base.set(foreign_key => base.send(foreign_key).clear)
            end
            after_remove_error = nil
            many_to_many = target.clear do |doc|
              unbind_one(doc)
              unless __association.forced_nil_inverse?
                doc.changed_attributes.delete(inverse_foreign_key)
              end
              begin
                execute_callback :after_remove, doc
              rescue => e
                after_remove_error = e
              end
            end
            raise after_remove_error if after_remove_error
            many_to_many
          end

          alias :nullify_all :nullify
          alias :clear :nullify
          alias :purge :nullify

          # Substitutes the supplied target documents for the existing documents
          # in the relation. If the new target is nil, perform the necessary
          # deletion.
          #
          # @example Replace the relation.
          # person.preferences.substitute([ new_post ])
          #
          # @param [ Array<Document> ] replacement The replacement target.
          #
          # @return [ Many ] The relation.
          #
          # @since 2.0.0.rc.1
          def substitute(replacement)
            purge(replacement)
            unless replacement.blank?
              push(replacement.compact.uniq)
            else
              reset_unloaded
            end
            self
          end

          # Get a criteria for the documents without the default scoping
          # applied.
          #
          # @example Get the unscoped criteria.
          #   person.preferences.unscoped
          #
          # @return [ Criteria ] The unscoped criteria.
          #
          # @since 2.4.0
          def unscoped
            klass.unscoped.any_in(_id: base.send(foreign_key))
          end

          private

          # Appends the document to the target array, updating the index on the
          # document at the same time.
          #
          # @example Append the document to the relation.
          #   relation.append(document)
          #
          # @param [ Document ] document The document to append to the target.
          #
          # @since 2.0.0.rc.1
          def append(document)
            execute_callback :before_add, document
            target.push(document)
            characterize_one(document)
            bind_one(document)
            execute_callback :after_add, document
          end

          # Instantiate the binding associated with this relation.
          #
          # @example Get the binding.
          #   relation.binding([ address ])
          #
          # @return [ Binding ] The binding.
          #
          # @since 2.0.0.rc.1
          def binding
            HasAndBelongsToMany::Binding.new(base, target, __association)
          end

          # Determine if the child document should be persisted.
          #
          # @api private
          #
          # @example Is the child persistable?
          #   relation.child_persistable?(doc)
          #
          # @param [ Document ] doc The document.
          #
          # @return [ true, false ] If the document can be persisted.
          #
          # @since 3.0.20
          def child_persistable?(doc)
            (persistable? || _creating?) &&
                !(doc.persisted? && __association.forced_nil_inverse?)
          end

          # Returns the criteria object for the target class with its documents set
          # to target.
          #
          # @example Get a criteria for the relation.
          #   relation.criteria
          #
          # @return [ Criteria ] A new criteria.
          def criteria(id_list = nil)
            __association.criteria(base, id_list)
          end

          # Flag the base as unsynced with respect to the foreign key.
          #
          # @api private
          #
          # @example Flag as unsynced.
          #   relation.unsynced(doc, :preference_ids)
          #
          # @param [ Document ] doc The document to flag.
          # @param [ Symbol ] key The key to flag on the document.
          #
          # @return [ true ] true.
          #
          # @since 3.0.0
          def unsynced(doc, key)
            doc._synced[key] = false
            true
          end

          class << self

            # Get the Eager object for this type of association.
            #
            # @example Get the eager loader object
            #
            # @param [ Association ] The association object.
            # @param [ Array<Document> ] The array of documents.
            #
            # @since 7.0
            def eager_loader(association, docs)
              Eager.new(association, docs)
            end

            # Returns true if the relation is an embedded one. In this case
            # always false.
            #
            # @example Is this relation embedded?
            #   Referenced::ManyToMany.embedded?
            #
            # @return [ false ] Always false.
            #
            # @since 2.0.0.rc.1
            def embedded?
              false
            end
          end
        end
      end
    end
  end
end