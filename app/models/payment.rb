# encoding: utf-8
# author: Boris Barroso
# email: boriscyber@gmail.com
class Payment < ActiveRecord::Base
  acts_as_org

  attr_reader :pay_plan, :updated_pay_plan_ids

  # callbacks
  after_initialize :set_defaults, :if => :new_record?
  before_create :set_currency_id, :if => :new_record?
  before_create :set_cash_amount, :if => :transaction_cash?
  after_save  :update_transaction
  after_save  :update_pay_plan
  after_save  :create_account_ledger

  # relationships
  belongs_to :transaction
  belongs_to :account
  belongs_to :currency
  belongs_to :contact
  has_many :account_ledgers

  delegate :state, :type, :cash, :cash?, :paid?, :balance, :contact_id, :to => :transaction, :prefix => true

  delegate :name, :symbol, :to => :currency, :prefix => true

  # validations
  validates_presence_of :account_id, :transaction_id
  validate :valid_payment_amount, :if => :active?
  validate :valid_amount_or_interests_penalties, :if => :active?

  # scopes
  #default_scope where(:organisation_id => OrganisationSession.organisation_id)
  scope :active, where(:active => true)

  # Overide the dault to_json method
  def to_json
    self.attributes.merge(
      :updated_pay_plan_ids => @updated_pay_plan_ids, 
      :pay_plan => @pay_plan, 
      :account => account.to_s, 
      :total_amount => total_amount,
      :transaction_paid => transaction_paid?
    ).to_json
  end

  # Sums the amount plus the interests and penalties
  def total_amount
    amount + interests_penalties
  end

  # Nulls a payment
  def null_payment
    if active and !transaction_paid?
      self.active = false
      self.save
    end
  end

private
  def set_defaults
    self.amount ||= 0
    self.interests_penalties ||= 0
    self.active = true if active.nil?
  end

  def update_transaction
    if active
      transaction.add_payment(amount)
    else
      transaction.substract_payment(amount)
    end
  end

  def set_currency_id
    self.currency_id = transaction.currency_id
  end

  # Updates the related pay_plans of a transaction setting to pay
  # according to the amount and interest penalties
  def update_pay_plan
    amount_to_pay = 0
    interest_to_pay = 0
    created_pay_plan = nil
    amount_to_pay = amount
    interest_to_pay = interests_penalties
    @updated_pay_plan_ids = []

    transaction.pay_plans.unpaid.each do |pp|
      amount_to_pay += - pp.amount
      interest_to_pay += - pp.interests_penalties

      pp.update_attribute(:paid, true)
      @updated_pay_plan_ids << pp.id

      if amount_to_pay <= 0
        @pay_plan = create_pay_plan(amount_to_pay, interest_to_pay) if amount_to_pay < 0 or interest_to_pay < 0
        break
      end
    end
  end

  # Creates a new pay_plan
  def create_pay_plan(amt, int_pen)
    amt = amt < 0 ? -1 * amt : 0
    int_pen = int_pen < 0 ? -1 * int_pen : 0
    d = Date.today + 1.day
    p = PayPlan.create(:transaction_id => transaction_id, :amount => amt, :interests_penalties => int_pen,
                    :payment_date => d, :alert_date => d )
  end

  def valid_payment_amount
    if amount > transaction.balance
      self.errors.add(:amount, "La cantidad ingresada es mayor que el saldo por pagar.")
    end
  end

  # Checks that anny of the values is set to greater than 0
  def valid_amount_or_interests_penalties
    if self.amount <= 0 and interests_penalties <= 0
      self.errors.add(:amount, "Debe ingresar una cantidad mayor a 0 para Cantidad o Intereses/Penalidades")
    end
  end

  # Creates an account ledger for the account and payment
  def create_account_ledger
    if transaction.type == "Income"
      tot, income = [total_amount, true]
      tot, income = [-total_amount, false] unless active?
    else
      tot, income = [-total_amount, true]
      tot, income = [total_amount, false] unless active?
    end

    AccountLedger.create(:account_id => account_id, :payment_id => id, 
                         :currency_id => currency_id, :contact_id => transaction_contact_id,
                         :amount => tot, :date => date, :income => income)
  end

  # Sets the amount for cash
  def set_cash_amount
    self.amount = transaction_balance
  end
end