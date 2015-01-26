# require 'open-uri'
# require 'savon'
require 'nokogiri'

class TrainingPeaks
  TPBASE= 'http://www.trainingpeaks.com/tpwebservices/service.asmx'
  TPWSDL= TPBASE + '?WSDL'

  @@client = nil

  attr_accessor :user, :password, :client, :guid, :athletes, :personID

  #
  # you can init the class without a user/password, but you'll need one soon enough
  # use the user & password setters
  def initialize( aUser=nil, aPassword=nil )
    @user= aUser
    @password= aPassword

    @guid=nil          # returned from authenticate
    @athletes=nil
    @personID=nil      # needed for lots of calls
  end

  def getClient
    @@client = openClient if @@client.nil?

    @@client
  end

  def openClient
    @@client = Savon.client( wsdl: TPWSDL ) if @@client.nil?

    Rails.logger.error "Can't open TrainingPeaks Client" if @@client.nil?

    @@client
  end

  #
  # callTP depends on the client being open.  Be sure to check that outside of this function
  #
  def callTP( method, params=nil )
    cl= getClient
    return nil if cl.nil?

    msg = { username: @user, password: @password }
    msg = msg.each_with_object( params ) { |(k,v), h| h[k] = v } if !params.nil?
    resp = cl.call( method.to_sym, message: msg )
  rescue Savon::Error => e
    Rails.logger.error "Error using Savon to authenticate user, #{e}"
    nil
  end

  def authenticateAccount( aUser=nil, aPassword=nil )
    @user = aUser unless aUser.nil?
    @password = aPassword unless aPassword.nil?

    if ( @user.nil? || @password.nil? )
      Rails.logger.error "Can't authenticate TrainingPeaks users without non-nil userid and password"
    else
      resp = callTP( :authenticate_account )
      return false if resp.nil?

      @guid = resp.body[:authenticate_account_response][:authenticate_account_result]
    end

    !@guid.nil?   # if guid is non-nil, it worked!
  end

  def getAccessibleAthletes( athTypes= ["CoachedPremium",
                                        "SelfCoachedPremium",
                                        "SharedSelfCoachedPremium",
                                        "SharedCoachedPremium",
                                        "CoachedFree",
                                        "SharedFree",
                                        "Plan"] )

    resp = callTP( :get_accessible_athletes, { types: athTypes } )
    @athletes = resp.body[:get_accessible_athletes_response][:get_accessible_athletes_result]
  end

  #
  # reads array of accessible athletes for the account, @user to find the matching athlete with username
  # returns the personID for that athlete
  # if username is nil, will attempt to match an athlete where username == @user
  #
  def getPersonID( username=nil )
    matchuser = username.nil? ? @user : username

    getAccessibleAthletes() if @athletes.nil?

    if @athletes.nil? or @athletes.length() != 1
      Rails.logger.error "TrainingPeaks returned number of athletes other than 1"
    else
      person = @athletes[:person_base]
      @personID = person[:person_id] if !person.nil? and person[:username] == matchuser
    end

    @personID
  end

  #
  # retrieves historical or future scheduled workouts for the current personID (set with getPersonID)
  # for date range.  dates are of format YYYY-MM-DD, e.g. "2014-10-24"
  #
  def getWorkouts( start_date, end_date )
    workouts = nil

    getPersonID if @personID.nil?

    unless @personID.nil?
      resp = callTP( :get_workouts_for_accessible_athlete,
          { personId: @personID, startDate: start_date, endDate: end_date } )

      if (!resp.body.nil? && !resp.body[:get_workouts_for_accessible_athlete_response].nil? &&
        !resp.body[:get_workouts_for_accessible_athlete_response][:get_workouts_for_accessible_athlete_result].nil? &&
        !resp.body[:get_workouts_for_accessible_athlete_response][:get_workouts_for_accessible_athlete_result][:workout].nil? )

          workouts = resp.body[:get_workouts_for_accessible_athlete_response][:get_workouts_for_accessible_athlete_result][:workout]
      end
    end

    workouts
  end

  #
  # gets workout data (PWX file) for a single workoutID or array of workoutID(s)
  #
  def getWorkoutData( workoutID )
    getPersonID if @personID.nil?

    return nil if @personID.nil?

    resp = callTP( :get_extended_workouts_for_accessible_athlete,
        { personId: @personID, workoutIds: workoutID } )

    resp.body[:get_extended_workouts_for_accessible_athlete_response][:get_extended_workouts_for_accessible_athlete_result][:pwx]
  end

  def saveWorkoutDataToFile( workoutID, filename )
    url = getDownloadUrl( workoutID )

    return false if url.nil?

    open( filename, 'wb' ) do |f|
      f << open( url ).read
    end
    true
  end

  def loadFile( aFileName )
    pwx_doc = nil
    if !aFileName.nil? && aFileName != ""
      File.open( aFileName ) do |f|
        pwx_doc = Nokogiri::XML( f )
      end
    end

    pwx_doc
  end

  def getDownloadUrl( workoutID )
    getPersonID if @personID.nil?

    return nil if @personID.nil?

    params = { username: @user,
              password: @password,
              personId: @personID,
              workoutIds: workoutID }

    TPBASE + "/GetExtendedWorkoutsForAccessibleAthlete" + '?' + params.map{|e| e.join('=')}.join('&')
  end

  def getNodeFloatAndAttrHash( node )
    result = nil

    if node.attributes.length <= 0
     result = node.text.to_f
    else
     result = {}
     node.attributes.each do |k,v|
       result[k] = v.value.to_f
     end
    end

    result
  end

  def getSummary( pwx_doc )
    summary = {}

    if !pwx_doc.nil?
      workoutSummary = pwx_doc.xpath( "//xmlns:workout" )
      # workoutSummary = pwx_doc.xpath( "//xmlns:workout/xmlns:summarydata" )

      workoutSummary.children.each do |n|
        next if n.class != Nokogiri::XML::Element

        summary[n.name] = getNodeFloatAndAttrHash( n )
      end
    end

    summary
  end

  def getSegments( pwx_doc )
    segments = []

    if !pwx_doc.nil?
      pwx_doc.xpath( "//xmlns:workout/xmlns:segment" ).each do |s|
        sh = {}
        s.xpath( "xmlns:summarydata" ).children.each do |c|
          next if c.class != Nokogiri::XML::Element

          sh[c.name] = getNodeFloatAndAttrHash( c )
        end

        segments << { s.xpath( "xmlns:name" ).text=> sh }
      end
    end

    segments
  end

  def getSamples( pwx_doc )
    samples = []

    if !pwx_doc.nil?
      pwx_doc.xpath( "//xmlns:workout/xmlns:sample" ).each do |s|
        sa = {}
        s.children.each do |c|
          next if c.class != Nokogiri::XML::Element
          sa[c.name] = c.text.to_f
        end

        samples << sa
      end
    end

    samples
  end

  def get_ride_start_time( pwx_doc )
    start_time = nil

    if !pwx_doc.nil?
      time_element = pwx_doc.xpath( "//xmlns:workout/xmlns:time" )
      start_time = Time.parse time_element.children.text if time_element.class == Nokogiri::XML::NodeSet and time_element.children.class == Nokogiri::XML::NodeSet
    end

    start_time
  end

  def get_ride_comment( pwx_doc )
    comment = nil

    if !pwx_doc.nil?
      comment_element = pwx_doc.xpath( "//xmlns:workout/xmlns:cmt" )
      comment = comment_element.children.text if comment_element.class == Nokogiri::XML::NodeSet and comment_element.children.class == Nokogiri::XML::NodeSet
    end

    comment
  end

  def pwx_get_file_data( pwx_doc )
    ride_data = []

    if !pwx_doc.nil?
      pwx_doc.xpath( "//xmlns:workout/xmlns:sample" ).each do |s|
        sa = {}
        s.children.each do |c|
          next if c.class != Nokogiri::XML::Element
          sa[c.name] = c.name == "timeoffset" ? c.text.to_i : c.text.to_f
        end
        ride_data << sa
      end
    end
    ride_data
  end
end
