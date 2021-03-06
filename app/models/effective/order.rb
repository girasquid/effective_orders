module Effective
  class Order < ActiveRecord::Base
    self.table_name = EffectiveOrders.orders_table_name.to_s

    if EffectiveOrders.obfuscate_order_ids
      acts_as_obfuscated format: '###-####-###'
    end

    acts_as_addressable(
      :billing => { singular: true, use_full_name: EffectiveOrders.use_address_full_name },
      :shipping => { singular: true, use_full_name: EffectiveOrders.use_address_full_name }
    )

    attr_accessor :save_billing_address, :save_shipping_address # save these addresses to the user if selected
    attr_accessor :terms_and_conditions # Yes, I agree to the terms and conditions

    # Settings in the /admin action forms
    attr_accessor :send_payment_request_to_buyer # Used by the /admin/orders/new form. Should the payment request email be sent after creating an order?
    attr_accessor :send_mark_as_paid_email_to_buyer  # Used by the /admin/orders/mark_as_paid action
    attr_accessor :skip_buyer_validations # Enabled by the /admin/orders/create action

    belongs_to :user, validate: false  # This is the user who purchased the order. We validate it below.
    has_many :order_items, inverse_of: :order

    # structure do
    #   purchase_state    :string
    #   purchased_at      :datetime
    #
    #   note              :text
    #
    #   payment           :text   # serialized hash containing all the payment details.  see below.
    #
    #   payment_provider  :string
    #   payment_card      :string
    #
    #   tax_rate          :decimal, precision: 6, scale: 3
    #
    #   subtotal          :integer
    #   tax               :integer
    #   total             :integer
    #
    #   timestamps
    # end

    accepts_nested_attributes_for :order_items, allow_destroy: false, reject_if: :all_blank
    accepts_nested_attributes_for :user, allow_destroy: false, update_only: true

    before_validation { assign_totals! }
    before_save { assign_totals! unless self[:total].present? } # Incase we save!(validate: false)

    unless EffectiveOrders.skip_user_validation
      validates :user_id, presence: true, unless: Proc.new { |order| order.skip_buyer_validations? }
      validates :user, associated: true, unless: Proc.new { |order| order.skip_buyer_validations? }
    end

    if EffectiveOrders.collect_note_required
      validates :note, presence: true, unless: Proc.new { |order| order.skip_buyer_validations? }
    end

    validates :tax_rate, presence: { message: "can't be determined based on billing address" }, unless: Proc.new { |order| order.skip_buyer_validations? }
    validates :tax, presence: true, unless: Proc.new { |order| order.skip_buyer_validations? }

    if EffectiveOrders.require_billing_address  # An admin creating a new pending order should not be required to have addresses
      validates :billing_address, presence: true, unless: Proc.new { |order| (order.new_record? && order.pending?) || order.skip_buyer_validations? }
    end

    if EffectiveOrders.require_shipping_address  # An admin creating a new pending order should not be required to have addresses
      validates :shipping_address, presence: true, unless: Proc.new { |order| (order.new_record? && order.pending?) || order.skip_buyer_validations? }
    end

    if ((minimum_charge = EffectiveOrders.minimum_charge.to_i) rescue nil).present?
      if EffectiveOrders.allow_free_orders
        validates :total, numericality: {
          greater_than_or_equal_to: minimum_charge,
          message: "A minimum order of #{EffectiveOrders.minimum_charge} is required.  Please add additional items to your cart."
        }, unless: Proc.new { |order| order.total == 0 }
      else
        validates :total, numericality: {
          greater_than_or_equal_to: minimum_charge,
          message: "A minimum order of #{EffectiveOrders.minimum_charge} is required.  Please add additional items to your cart."
        }
      end
    end

    validates :purchase_state, inclusion: { in: [nil, EffectiveOrders::PURCHASED, EffectiveOrders::DECLINED, EffectiveOrders::PENDING] }

    validates :subtotal, presence: true
    validates :total, presence: true

    validates :order_items, presence: { message: 'No items are present.  Please add one or more item to your cart.' }
    validates :order_items, associated: true

    with_options if: Proc.new { |order| order.purchased? } do |order|
      order.validates :purchased_at, presence: true
      order.validates :payment, presence: true

      order.validates :payment_provider, presence: true, inclusion: { in: EffectiveOrders.payment_providers + EffectiveOrders.other_payment_providers }
      order.validates :payment_card, presence: true
    end

    serialize :payment, Hash

    default_scope -> { includes(:user).includes(order_items: :purchasable).order(created_at: :desc) }

    scope :purchased, -> { where(purchase_state: EffectiveOrders::PURCHASED) }
    scope :purchased_by, lambda { |user| purchased.where(user_id: user.try(:id)) }
    scope :declined, -> { where(purchase_state: EffectiveOrders::DECLINED) }
    scope :pending, -> { where(purchase_state: EffectiveOrders::PENDING) }
    scope :for_users, -> (users) {   # Expects a Users relation, an Array of ids, or Array of users
      users = users.kind_of?(::ActiveRecord::Relation) ? users.pluck(:id) : Array(users)
      where(user_id: (users.first.kind_of?(Integer) ? users : users.map { |user| user.id }))
    }

    # Effective::Order.new()
    # Effective::Order.new(Product.first)
    # Effective::Order.new(Product.all)
    # Effective::Order.new(Product.first, user: User.first)
    # Effective::Order.new(Product.first, Product.second, user: User.first)
    # Effective::Order.new(user: User.first)
    # Effective::Order.new(current_cart)

    # items can be an Effective::Cart, a single acts_as_purchasable, or an array of acts_as_purchasables
    def initialize(*items, user: nil, billing_address: nil, shipping_address: nil)
      super() # Call super with no arguments

      # Set up defaults
      self.save_billing_address = true
      self.save_shipping_address = true

      self.user = user || (items.first.user if items.first.kind_of?(Effective::Cart))

      if billing_address
        self.billing_address = billing_address
        self.billing_address.full_name ||= billing_name
      end

      if shipping_address
        self.shipping_address = shipping_address
        self.shipping_address.full_name ||= billing_name
      end

      add(items) if items.present?
    end

    # add(Product.first) => returns an Effective::OrderItem
    # add(Product.first, current_cart) => returns an array of Effective::OrderItems
    def add(*items, quantity: 1)
      raise 'unable to alter a purchased order' if purchased?
      raise 'unable to alter a declined order' if declined?

      cart_items = items.flatten.flat_map do |item|
        if item.kind_of?(Effective::Cart)
          item.cart_items.to_a
        elsif item.kind_of?(ActsAsPurchasable)
          Effective::CartItem.new(quantity: quantity.to_i).tap { |cart_item| cart_item.purchasable = item }
        else
          raise ArgumentError.new('Effective::Order.add() expects one or more acts_as_purchasable objects, or an Effective::Cart')
        end
      end

      # Make sure to reset stored aggregates
      self.total = nil
      self.subtotal = nil
      self.tax = nil

      retval = cart_items.map do |item|
        order_items.build(
          title: item.title,
          quantity: item.quantity,
          price: item.price,
          tax_exempt: item.tax_exempt || false,
          seller_id: (item.purchasable.try(:seller).try(:id) rescue nil)
        ).tap { |order_item| order_item.purchasable = item.purchasable }
      end

      retval.size == 1 ? retval.first : retval
    end
    alias_method :add_to_order, :add

    def user=(user)
      return if user.nil?

      super

      # Copy user addresses into this order if they are present
      if user.respond_to?(:billing_address) && user.billing_address.present?
        self.billing_address = user.billing_address
      end

      if user.respond_to?(:shipping_address) && user.shipping_address.present?
        self.shipping_address = user.shipping_address
      end

      # If our addresses are required, make sure they exist
      if EffectiveOrders.require_billing_address
        self.billing_address ||= Effective::Address.new()
      end

      if EffectiveOrders.require_shipping_address
        self.shipping_address ||= Effective::Address.new()
      end

      # Ensure the Full Name is assigned when an address exists
      if billing_address.present? && billing_address.full_name.blank?
        self.billing_address.full_name = billing_name
      end

      if shipping_address.present? && shipping_address.full_name.blank?
        self.shipping_address.full_name = billing_name
      end
    end

    # This is called from admin/orders#create
    # This is intended for use as an admin action only
    # It skips any address or bad user validations
    def create_as_pending
      self.purchase_state = EffectiveOrders::PENDING

      self.skip_buyer_validations = true
      self.addresses.clear if addresses.any? { |address| address.valid? == false }

      return false unless save

      send_payment_request_to_buyer! if send_payment_request_to_buyer?
      true
    end

    # This is used for updating Subscription codes.
    # We want to update the underlying purchasable object of an OrderItem
    # Passing the order_item_attributes using rails default acts_as_nested creates a new object instead of updating the temporary one.
    # So we override this method to do the updates on the non-persisted OrderItem objects
    # Right now strong_paramaters only lets through stripe_coupon_id
    # {"0"=>{"class"=>"Effective::Subscription", "stripe_coupon_id"=>"50OFF", "id"=>"2"}}}
    def order_items_attributes=(order_item_attributes)
      if self.persisted? == false
        (order_item_attributes || {}).each do |_, atts|
          order_item = self.order_items.find { |oi| oi.purchasable.class.name == atts[:class] && oi.purchasable.id == atts[:id].to_i }

          if order_item
            order_item.purchasable.attributes = atts.except(:id, :class)

            # Recalculate the OrderItem based on the updated purchasable object
            order_item.title = order_item.purchasable.title
            order_item.price = order_item.purchasable.price
            order_item.tax_exempt = order_item.purchasable.tax_exempt
            order_item.seller_id = (order_item.purchasable.try(:seller).try(:id) rescue nil)
          end
        end
      end
    end

    def purchasables
      order_items.map { |order_item| order_item.purchasable }
    end

    def tax_rate
      self[:tax_rate] || get_tax_rate()
    end

    def tax
      self[:tax] || get_tax()
    end

    def subtotal
      self[:subtotal] || order_items.map { |oi| oi.subtotal }.sum
    end

    def total
      self[:total] || [(subtotal + tax.to_i), 0].max
    end

    def num_items
      order_items.map { |oi| oi.quantity }.sum
    end

    def save_billing_address?
      truthy?(self.save_billing_address)
    end

    def save_shipping_address?
      truthy?(self.save_shipping_address)
    end

    def send_payment_request_to_buyer?
      truthy?(self.send_payment_request_to_buyer)
    end

    def send_mark_as_paid_email_to_buyer?
      truthy?(self.send_mark_as_paid_email_to_buyer)
    end

    def skip_buyer_validations?
      truthy?(self.skip_buyer_validations)
    end

    def billing_name
      name ||= billing_address.try(:full_name).presence
      name ||= user.try(:full_name).presence
      name ||= (user.try(:first_name).to_s + ' ' + user.try(:last_name).to_s).presence
      name ||= user.try(:email).presence
      name ||= user.to_s
      name ||= "User #{user.try(:id)}"
      name
    end

    # Effective::Order.new(Product.first, user: User.first).purchase!(details: 'manual purchase')
    # order.purchase!(details: {key: value})
    def purchase!(details: 'none', provider: 'none', card: 'none', validate: true, email: true, skip_buyer_validations: false)
      return false if purchased?

      success = false

      Effective::Order.transaction do
        begin
          self.purchase_state = EffectiveOrders::PURCHASED
          self.purchased_at ||= Time.zone.now

          self.payment = details.kind_of?(Hash) ? details : { details: details.to_s }
          self.payment_provider = provider.to_s
          self.payment_card = card.to_s.presence || 'none'

          self.skip_buyer_validations = skip_buyer_validations

          save!(validate: validate)

          order_items.each { |item| (item.purchasable.purchased!(self, item) rescue nil) }

          success = true
        rescue => e
          self.purchase_state = purchase_state_was
          self.purchased_at = purchased_at_was

          raise ::ActiveRecord::Rollback
        end
      end

      send_order_receipts! if (success && email)

      raise "Failed to purchase Effective::Order: #{self.errors.full_messages.to_sentence}" unless success
      success
    end

    def decline!(details: 'none', provider: 'none', card: 'none', validate: true)
      return false if declined?

      raise EffectiveOrders::AlreadyPurchasedException.new('order already purchased') if purchased?

      success = false

      Effective::Order.transaction do
        begin
          self.purchase_state = EffectiveOrders::DECLINED
          self.purchased_at = nil

          self.payment = details.kind_of?(Hash) ? details : { details: details.to_s }
          self.payment_provider = provider.to_s
          self.payment_card = card.to_s.presence || 'none'

          save!(validate: validate)

          order_items.each { |item| (item.purchasable.declined!(self, item) rescue nil) }

          success = true
        rescue => e
          raise ::ActiveRecord::Rollback
        end
      end

      raise "Failed to decline! Effective::Order: #{self.errors.full_messages.to_sentence}" unless success
      success
    end

    def purchased?(provider = nil)
      return false if (purchase_state != EffectiveOrders::PURCHASED)
      return true if provider.nil? || payment_provider == provider.to_s

      unless EffectiveOrder.payment_providers.include?(provider.to_s)
        raise "Unknown provider #{provider}. Known providers are #{EffectiveOrders.payment_providers}"
      end
    end

    def declined?
      purchase_state == EffectiveOrders::DECLINED
    end

    def pending?
      purchase_state == EffectiveOrders::PENDING
    end

    def send_order_receipts!
      send_order_receipt_to_admin! if EffectiveOrders.mailer[:send_order_receipt_to_admin]
      send_order_receipt_to_buyer! if EffectiveOrders.mailer[:send_order_receipt_to_buyer]
      send_order_receipt_to_seller! if EffectiveOrders.mailer[:send_order_receipt_to_seller]
    end

    def send_order_receipt_to_admin!
      send_email(:order_receipt_to_admin, to_param) if purchased?
    end

    def send_order_receipt_to_buyer!
      send_email(:order_receipt_to_buyer, to_param) if purchased?
    end

    def send_order_receipt_to_seller!
      return false unless (EffectiveOrders.stripe_connect_enabled && purchased?(:stripe_connect))

      order_items.group_by(&:seller).each do |seller, order_items|
        send_email(:order_receipt_to_seller, to_param, seller, order_items)
      end
    end

    def send_payment_request_to_buyer!
      send_email(:payment_request_to_buyer, to_param) if !purchased?
    end

    def send_pending_order_invoice_to_buyer!
      send_email(:pending_order_invoice_to_buyer, to_param) if !purchased?
    end

    protected

    def get_tax_rate
      self.instance_exec(self, &EffectiveOrders.order_tax_rate_method).tap do |rate|
        rate = rate.to_f
        if (rate > 100.0 || (rate < 0.25 && rate > 0.0000))
          raise "expected EffectiveOrders.order_tax_rate_method to return a value between 100.0 (100%) and 0.25 (0.25%) or 0 or nil. Received #{rate}. Please return 5.25 for 5.25% tax."
        end
      end
    end

    def get_tax
      return nil unless tax_rate.present?
      amount = order_items.reject { |oi| oi.tax_exempt? }.map { |oi| (oi.subtotal * (tax_rate / 100.0)).round(0).to_i }.sum
      [amount, 0].max
    end

    private

    def assign_totals!
      self.subtotal = order_items.map { |oi| oi.subtotal }.sum
      self.tax_rate = get_tax_rate()
      self.tax = get_tax()
      self.total = [subtotal + (tax || 0), 0].max
    end

    def send_email(email, *mailer_args)
      begin
        if EffectiveOrders.mailer[:delayed_job_deliver] && EffectiveOrders.mailer[:deliver_method] == :deliver_later
          Effective::OrdersMailer.delay.public_send(email, *mailer_args)
        elsif EffectiveOrders.mailer[:deliver_method].present?
          Effective::OrdersMailer.public_send(email, *mailer_args).public_send(EffectiveOrders.mailer[:deliver_method])
        else
          Effective::OrdersMailer.public_send(email, *mailer_args).deliver_now
        end
      rescue => e
        raise e unless Rails.env.production?
        return false
      end
    end

    def truthy?(value)
      if defined?(::ActiveRecord::ConnectionAdapters::Column::TRUE_VALUES)  # Rails <5
        ::ActiveRecord::ConnectionAdapters::Column::TRUE_VALUES.include?(value)
      else
        ::ActiveRecord::Type::Boolean.new.cast(value)
      end
    end

  end
end
