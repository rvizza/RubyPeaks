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
    if ( @@client.nil? ) #&& !@user.nil? && !@password.nil? )
      @@client = Savon.client( wsdl: TPWSDL )
    end

    if ( @@client.nil? )
      Rails.logger.error "Can't open TrainingPeaks Client"
    end

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

  def getAccessibleAthletes( athTypes= ["CoachedPremium", "SelfCoachedPremium", "SharedSelfCoachedPremium", "SharedCoachedPremium", "CoachedFree", "SharedFree", "Plan"] )
    athletes=nil

    resp = callTP( :get_accessible_athletes, { types: athTypes } )
    athletes = resp.body[:get_accessible_athletes_response][:get_accessible_athletes_result]

    @athletes = athletes
  end

  #
  # reads array of accessible athletes for the account, @user to find the matching athlete with username
  # returns the personID for that athlete
  # if username is nil, will attempt to match an athlete where username == @user
  #
  def usePersonIDfromUsername( username=nil )
    id = nil

    matchuser = username.nil? ? @user : username

    if @athletes.nil?
      getAccessibleAthletes()
    end

    if @athletes.nil? or @athletes.length() != 1
      Rails.logger.error "TrainingPeaks returned number of athletes other than 1"
    end

    person = @athletes[:person_base]
    if !person.nil? and person[:username] == matchuser
      id = person[:person_id]
    end

    @personID = id
  end

  #
  # retrieves historical or future scheduled workouts for the current personID (set with usePersonIDfromUsername)
  # for date range.  dates are of format YYYY-MM-DD, e.g. "2014-10-24"
  #
  def getWorkouts( start_date, end_date )
    workouts = nil

    if ( @personID.nil? )
      # personID not set... try for current user
      usePersonIDfromUsername()
    end

    resp = callTP( :get_workouts_for_accessible_athlete,
        { personId: @personID, startDate: start_date, endDate: end_date } )

    if (!resp.body.nil? && !resp.body[:get_workouts_for_accessible_athlete_response].nil? &&
      !resp.body[:get_workouts_for_accessible_athlete_response][:get_workouts_for_accessible_athlete_result].nil? &&
      !resp.body[:get_workouts_for_accessible_athlete_response][:get_workouts_for_accessible_athlete_result][:workout].nil? )

        workouts = resp.body[:get_workouts_for_accessible_athlete_response][:get_workouts_for_accessible_athlete_result][:workout]
    end

    workouts
  end

  #
  # gets workout data (PWX file) for a single workoutID or array of workoutID(s)
  #
  def getWorkoutData( workoutID )
    usePersonIDfromUsername() if @personID.nil?

    resp = callTP( :get_extended_workouts_for_accessible_athlete,
        { personId: @personID, workoutIds: workoutID } )

    resp.body[:get_extended_workouts_for_accessible_athlete_response][:get_extended_workouts_for_accessible_athlete_result][:pwx]
  end

  def saveWorkoutDataToFile( workoutID, filename )
    usePersonIDfromUsername() if @personID.nil?

    params = { username: @user,
              password: @password,
              personId: @personID,
              workoutIds: workoutID }

    url = TPBASE + "/GetExtendedWorkoutsForAccessibleAthlete" + '?' + params.map{|e| e.join('=')}.join('&')
    puts( url )

    open( filename, 'wb' ) do |f|
      f << open( url ).read
    end
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

  # PWX file format
  # <xsd:element name="timeoffset" type="xsd:double"/>
  # <!-- timeoffset is seconds offset from beginning of wkt  -->
  # <!--  Performance info  -->
  # <xsd:element name="hr" type="xsd:unsignedByte" minOccurs="0"/>
  # <!--  heart rate in bpm  -->
  # <xsd:element name="spd" type="xsd:double" minOccurs="0"/>
  # <!--  speed in mps  -->
  # <xsd:element name="pwr" type="xsd:short" minOccurs="0"/>
  # <!--  power in watts  -->
  # <xsd:element name="torq" type="xsd:double" minOccurs="0"/>
  # <!--  torque in N-m  -->
  # <xsd:element name="cad" type="xsd:unsignedByte" minOccurs="0"/>
  # <!--  cadence in rpm  -->
  # <!--  Position info  -->
  # <xsd:element name="dist" type="xsd:double" minOccurs="0"/>
  # <!--  distance in meters from beginning  -->
  # <xsd:element name="lat" type="latitudeType" minOccurs="0"/>
  # <xsd:element name="lon" type="longitudeType" minOccurs="0"/>
  # <xsd:element name="alt" type="xsd:double" minOccurs="0"/>
  # <!--  elevation in meters  -->
  # <xsd:element name="temp" type="xsd:double" minOccurs="0"/>
  # <!--  temperature in celcius  -->
  # <!--  Real time if available  -->
  # <xsd:element name="time" type="xsd:dateTime" minOccurs="0"/>

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

  def pwx_get_file_data( pwx_doc, caller_keys, min_val, max_val )
    ride_data = []

    if !pwx_doc.nil?
      prev_tstamp = 0
      pwx_doc.xpath( "//xmlns:workout/xmlns:sample" ).each do |s|
        sa = {}
        s.children.each do |c|
          next if c.class != Nokogiri::XML::Element or caller_keys[c.name].nil?
          sa[caller_keys[c.name]] = c.text.to_f
        end

        gap = sa[caller_keys["timeoffset"]].to_i - prev_tstamp - 1
        fill_gaps( ride_data, gap, caller_keys ) if gap > 0
        ride_data << sa
        prev_tstamp = sa[caller_keys["timeoffset"]].to_i
      end
    end

    validate_ride_data( ride_data, caller_keys, min_val, max_val )
  end

  def validate_ride_data( ride_data, caller_keys, min_val, max_val )
    timeoffset_caller_key = caller_keys.delete("timeoffset") # this stream has already been scrubbed
    valid_vals = Hash[*caller_keys.values.map {|k| [k, false]}.flatten]
    prev_vals = Hash[*caller_keys.values.map {|k| [k, 0.0]}.flatten]

    # search for valid data
    ride_data.each do |rd|
      valid_vals.keys.each do |caller_key|
        unless rd[caller_key].nil? or min_val[caller_key].nil? or max_val[caller_key].nil?
          if caller_keys["lat"] == caller_key
            if !valid_vals[caller_key]
              valid_vals[caller_key] = true
              prev_vals[caller_key] = rd[caller_key]
            end
          elsif caller_keys["long"] == caller_key
            if !valid_vals[caller_key]
              valid_vals[caller_key] = true
              prev_vals[caller_key] = rd[caller_key]
            end
          elsif !valid_vals[caller_key] and rd[caller_key] > min_val[caller_key] and rd[caller_key] < max_val[caller_key]
            valid_vals[caller_key] = true
            prev_vals[caller_key] = rd[caller_key]
          end
        end
      end
      break unless valid_vals.value?(false)
    end

    # remove pairs where there are no valid values, i.e. empty streams
    valid_vals.delete_if { |k,v| !v }

    # fix anomolous data in an otherwise clean stream
    ride_data.each do |rd|
      valid_vals.keys.each do |caller_key|
        if caller_keys["lat"] == caller_key
          rd[caller_key] = prev_vals[caller_key] if rd[caller_key].nil?
        elsif caller_keys["long"] == caller_key
          rd[caller_key] = prev_vals[caller_key] if rd[caller_key].nil?
        else
          rd[caller_key] = prev_vals[caller_key] if rd[caller_key].nil? or rd[caller_key] < min_val[caller_key] or rd[caller_key] > max_val[caller_key]
        end
        prev_vals[caller_key] = rd[caller_key]
      end
    end

    return ride_data, (valid_vals.keys << timeoffset_caller_key) # add back the caller key for timeoffset
  end

  # def valid_lat_long( min, max, lat_long)
  #   ll = lat_long
  #   if ll > max
  #     while (ll > max)
  #       ll -= max
  #     end
  #   end
  #   if ll < min
  #     while (ll < min)
  #       ll += min
  #     end
  #   end
  #   return ((ll < (min+1) || ll > (max-1)) ? false : true)
  # end

  def fill_gaps( ride_data, gap, caller_keys )
    recent = ride_data.last
    gap.times do |index|
      sa = {}
      sa[caller_keys["timeoffset"]]   = recent[caller_keys["timeoffset"]] + index + 1
      sa[caller_keys["lat"]]          = recent[caller_keys["lat"]]
      sa[caller_keys["long"]]         = recent[caller_keys["long"]]
      sa[caller_keys["distance"]]     = recent[caller_keys["distance"]]
      sa[caller_keys["alt"]]          = recent[caller_keys["alt"]]
      sa[caller_keys["hr"]]           = recent[caller_keys["hr"]]
      sa[caller_keys["temp"]]         = recent[caller_keys["temp"]]
      if (gap > 10)
        sa[caller_keys["watts"]]    = 0.0
        sa[caller_keys["spd"]]      = 0.0
        sa[caller_keys["cad"]]      = 0.0
      else
        sa[caller_keys["watts"]]    = recent[caller_keys["watts"]]
        sa[caller_keys["spd"]]      = recent[caller_keys["spd"]]
        sa[caller_keys["cad"]]      = recent[caller_keys["cad"]]
      end
      ride_data << sa
    end
  end

end
