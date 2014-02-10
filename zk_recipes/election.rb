module ZkRecipes
  module Election
    require 'heartbeat'
    HEARTBEAT_PERIOD = 2
    class ElectionCandidate
      def initialize(zk, app_name, data, election_ns, handler)
        @zk          = zk
        @namespace   = app_name
        @election_ns = election_ns
        @handler     = handler
        @prefix      = get_abs_path([@namespace, @election_ns]))
        @heartbeat   = ZkRecipes::Heartbeat.new(@zk, @namespace, HEARTBEAT_PERIOD)
        @started     = false
      end

      def get_absolute_path(crumbs)
        File.join([""] + crumbs)
      end

      def get_relative_path(prefix, suffix)
        File.join([prefix, suffix])
      end

      def current_candidates
        @zk.children(@prefix, :watch => false).grep(/^_vote_/).sort
      end

      def clear_parent_subscription
        if @parent_subscription
          @parent_subscription.unregister
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
      end

      def handle_parent_event(event)
        if event.node_deleted?
          vote!
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
        @path = @zk.create(get_relative_path(@prefix, "_vote_"), :data => @data, :mode => :ephemeral_sequential)
        vote!
      end

      def vote! 
        @candidates = current_candidates 
        if i_the_leader?
          handler.election_won!
          leader_ready
        else
          handler.election_lost!
          watch_parent
        end
      end
    end
  end
end
