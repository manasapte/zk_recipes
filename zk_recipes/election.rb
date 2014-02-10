module ZkRecipes
  module Election
    require_relative 'heartbeat'
    HEARTBEAT_PERIOD = 2
    class ElectionCandidate
      def initialize(zk, app_name, data, election_ns, handler)
        @zk          = zk
        @namespace   = app_name
        @election_ns = election_ns
        @handler     = handler
        @prefix      = get_absolute_path([@namespace, @election_ns])
        @heartbeat   = ZkRecipes::Heartbeat.new(@zk, @namespace, HEARTBEAT_PERIOD)
        @started     = false
      end

      def get_absolute_path(crumbs)
        File.join([""] + crumbs)
      end

      def get_relative_path(prefix, suffix)
        File.join([prefix, suffix])
      end

      def create_if_not_exists(path)
        unless @zk.exists?(path)
          @zk.create(path)
        end
      end

      def current_candidates
        @zk.children(@prefix, :watch => false).grep(/^_vote_/).sort
      end

      def clear_parent_subscription
        if @parent_subscription
          @parent_subscription.unregister
        end
      end

      def clear_leader_subscription
        if @leader_subscription
          @leader_subscription.unregister
        end
      end

      def i_the_leader?
        @candidates[0] == @path
      end

      def parent_path
        idx = @candidates.index(@path) 
        idx == 0 ? nil : @candidates[idx - 1]
      end

      def leader_ready 
        @zk.set(@leader_path, :data => @data)
      end

      def handle_parent_event(event)
        if event.node_deleted?
          vote!
        end
      end

      def handle_leader_event(event)
        if event.node_changed?
          @handler.leader_ready!
        end
      end

      def watch_leader
        @leader_path = get_relative_path(@prefix, "current_leader")
        @leader_subscription = @zk.register(@leader_path) do |event|
          handle_leader_event(event)
        end
        if !@zk.exists?(@leader_path, :watch => true)
          @zk.create(@leader_path, :data => "")
          @zk.stat(@leader_path, :watch => true)
        end
      end

      def watch_parent
        clear_parent_subscription
        loop do
          p_path = parent_path
          break if p_path.nil?
          @parent_subscription = @zk.register(p_path) do |event|
            handle_parent_event(event)
          end
          if !@zk.exists?(p_path, :watch => true) 
            clear_parent_suscription
          else
            break
          end
        end
      end

      def start
        return if @started
        @started = true
        @heartbeat.start
        create_if_not_exists(get_absolute_path([@namespace]))
        create_if_not_exists(get_absolute_path([@namespace, @election_ns]))
        @path = @zk.create(get_relative_path(@prefix, "_vote_"), :data => @data, :mode => :ephemeral_sequential)
        p "path is: "
        watch_leader
        vote!
        @heartbeat.join
      end

      def stop
        return unless @started
        @heartbeat.stop
      end

      def vote! 
        @candidates = current_candidates 
        if i_the_leader?
          clear_leader_subscription
          @handler.election_won!
          leader_ready
        else
          @handler.election_lost!
          watch_parent
          watch_leader
        end
      end
    end
  end
end
