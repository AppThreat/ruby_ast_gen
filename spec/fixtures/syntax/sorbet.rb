# frozen_string_literal: true
# min_ruby: 3.1

# Sorbet shapes, pinned by the has_sig contract specs: a sig block attaches to the def that
# follows it in the same statement list, abstract methods have empty bodies, and T::Struct
# props are plain sends.
module Sample
  class Payment
    extend T::Sig

    sig { params(amount: Integer, currency: String).returns(T.nilable(String)) }
    def format(amount, currency)
      "#{currency} #{amount}"
    end

    sig { abstract.void }
    def validate; end

    # The negative case for has_sig: no preceding sig block, no key.
    def without_sig
      validate
    end

    sig { params(other: Payment).returns(T::Boolean) }
    def ==(other)
      false
    end
  end

  class Audit < T::Struct
    extend T::Sig

    const :entries, T::Array[String]
    prop :label, String

    sig { returns(String) }
    def heading
      label
    end
  end

  class Reporter
    extend T::Sig

    sig { void }
    def self.log!(message)
      puts message
    end
  end
end
